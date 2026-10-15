import Foundation
import ProspectCore
import QuartzCore

/// Drives the show: the sheet, the playhead and the stage runner, and what
/// the operator's keys do to them. The app's views call in here and redraw
/// when `changed` fires; nothing here knows about windows.
@MainActor
public final class ShowController {
    public private(set) var show: Show
    public private(set) var playhead: Playhead
    public let runner: StageRunner
    private let now: () -> Double
    /// The live cue's timed continue, from GO or from it finishing: when
    /// the next cue fires by itself.
    private var continueAt: (cue: UUID, time: Double)?

    /// The one line the console shows about what just happened, if anything.
    public private(set) var message: String?

    public enum Mode: Sendable {
        /// The sheet and settings are locked. Every show opens in this mode.
        case show
        case edit
    }

    public private(set) var mode = Mode.show

    /// Where the projector window is. The app works this out from the
    /// connected displays and reports it here.
    public private(set) var projector = ProjectorState.closed

    /// Called whenever anything the console shows has changed.
    public var changed: () -> Void = {}
    /// Called after every edit with the sheet as it was before and a name for
    /// the Undo menu. The document registers the undo and marks itself edited.
    public var onEdit: ((_ before: Show, _ actionName: String) -> Void)?
    /// Called for an edit folded into the one before it, such as the rest of
    /// a slider drag: the document has changed, but there is no new undo step.
    public var onMergedEdit: (() -> Void)?
    private var lastCoalescing: (name: String, at: Double)?
    /// Same-named slider edits closer together than this are one undo step.
    public static let coalescingWindow = 1.0
    /// Called whenever a cue fires, by GO, a continue or a resume, for the
    /// crash record.
    public var onFire: ((Cue) -> Void)?
    /// Called with whether the stage needs the display link running.
    public var needsTicks: (Bool) -> Void = { _ in }

    /// - Parameters:
    ///   - renderers: The cue types this build can draw.
    ///   - now: The display link's timebase, `CACurrentMediaTime` on stage.
    public init(
        show: Show,
        warnings: [String] = [],
        mode: Mode = .show,
        renderers: [Cue.Kind: any CueRenderer] = [
            .title: TitleRenderer(), .image: ImageRenderer(), .video: VideoRenderer(), .blank: BlankRenderer(),
        ],
        now: @escaping () -> Double = CACurrentMediaTime
    ) {
        self.show = show
        self.mode = mode
        playhead = Playhead(show: show)
        runner = StageRunner(renderers: renderers)
        self.now = now
        message = Self.openingMessage(show, warnings: warnings)
        runner.geometry = show.settings.geometry
        // What a renderer finds wrong, such as a missing picture, goes to the
        // console. The stage carries on regardless.
        for case let reporter as ReportsProblems in renderers.values {
            reporter.onProblem = { [weak self] problem in self?.say(problem) }
        }
        for case let armer as ArmsCues in renderers.values {
            armer.onArmStateChange = { [weak self] in self?.changed() }
        }
        preloadNext()
    }

    /// Replaces the sheet. Nothing is on stage afterwards, blackout is off,
    /// and the first cue stands by.
    public func open(_ show: Show, warnings: [String] = []) {
        runner.unload()
        self.show = show
        playhead = Playhead(show: show)
        runner.blackout = false
        runner.geometry = show.settings.geometry
        mode = .show
        runner.showsGuides = false
        message = Self.openingMessage(show, warnings: warnings)
        preloadNext()
        changed()
    }

    private static func openingMessage(_ show: Show, warnings: [String]) -> String? {
        if let warning = warnings.first {
            return warnings.count > 1 ? "\(warning) (and \(warnings.count - 1) more)" : warning
        }
        return show.issues.first.map(show.message(for:))
    }

    // MARK: The operator's keys

    /// Space. The only way a cue is fired by hand.
    public func go() {
        guard let fire = playhead.go(in: show) else {
            say("End of the cue sheet. Press R to run the live cue again.")
            return
        }
        perform(fire)
    }

    public func standByNext() {
        playhead.standByNext(in: show)
        say(nil)
    }

    public func standByPrevious() {
        playhead.standByPrevious(in: show)
        say(nil)
    }

    /// A click on the cue list.
    public func standBy(_ id: UUID) {
        playhead.standBy(id)
        say(nil)
    }

    /// The Go-to field, which reaches numbers with letters in them.
    public func standBy(number: String) {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        say(playhead.standBy(number: trimmed, in: show) ? nil : "No cue is numbered \(trimmed).")
    }

    public func type(_ c: Character) {
        playhead.type(c)
        changed()
    }

    public func deleteBackward() {
        playhead.deleteBackward()
        changed()
    }

    public func clearEntry() {
        playhead.clearEntry()
        changed()
    }

    public func commitEntry() {
        switch playhead.commitEntry(in: show) {
        case .empty: changed()
        case .stoodBy: say(nil)
        case .noSuchCue(let number): say("No cue is numbered \(number).")
        }
    }

    public func rerun() {
        guard let fire = playhead.rerun() else {
            say("Nothing is on stage yet.")
            return
        }
        perform(fire)
    }

    public func toggleBlackout() {
        playhead.blackout.toggle()
        runner.blackout = playhead.blackout
        say(playhead.blackout ? "Blacked out. Press B to bring the picture back." : nil)
    }

    /// What the standby panel says about a video cue standing by: armed and
    /// ready, still loading, or not going to play. Nil for other cues.
    public var standbyArmState: ArmState? {
        guard let id = playhead.standby, let cue = show[id], cue.kind == .video else { return nil }
        return runner.armState(for: cue) ?? .arming
    }

    // MARK: Modes and settings

    /// Locks the sheet. Alignment guides switch themselves off, because left
    /// lit they would put a brass crosshair across the set.
    public func enterShowMode() {
        guard mode != .show else { return }
        mode = .show
        runner.showsGuides = false
        say("Show mode. The cue sheet and settings are locked.")
    }

    public func enterEditMode() {
        guard mode != .edit else { return }
        mode = .edit
        say("Edit mode.")
    }

    /// Alignment guides, on every surface. Edit mode only.
    public var showsGuides: Bool {
        get { runner.showsGuides }
        set {
            guard mode == .edit else { return }
            runner.showsGuides = newValue
            changed()
        }
    }

    /// Where the picture lands within the projector output. Edit mode only.
    public func setGeometry(_ geometry: Geometry, coalescing: Bool = false) {
        edit("Change Projection Area", coalescing: coalescing) { $0.settings.geometry = geometry }
    }

    /// The title printed at the head of the cue sheet.
    public func setTitle(_ title: String) {
        edit("Change Show Title") { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Changes one of the show's defaults. Every cue that doesn't set its own
    /// value runs with it from its next run; text size refits at once.
    public func setDefault(_ key: SettingKey, to value: SettingValue, coalescing: Bool = false) {
        edit("Change Default \(key.label)", coalescing: coalescing) { key.set(value, in: &$0.settings) }
    }

    /// Sets a cue's own value for a setting, or with nil puts it back on the
    /// show's default. Ignored for settings the cue's kind doesn't have.
    public func setOverride(_ key: SettingKey, to value: SettingValue?, for id: UUID, coalescing: Bool = false) {
        guard let cue = show[id], key.applies(to: cue.kind) else { return }
        let name = value == nil ? "Use Show\u{2019}s \(key.label)" : "Change \(key.label) for Cue \(cue.number)"
        edit(name, coalescing: coalescing) { show in
            guard let i = show.index(of: id) else { return }
            key.setOverride(value, in: &show.cues[i])
        }
    }

    /// The display the projector should use, kept with the show. Allowed in
    /// either mode: choosing a display is running the show, not editing it.
    /// In show mode the document isn't written, so the choice is kept in
    /// memory and saved with the next edit.
    public func setProjectorDisplay(_ display: DisplayIdentity) {
        guard show.settings.projector != display else { return }
        if mode == .edit {
            edit("Choose Projector Display") { $0.settings.projector = display }
        } else {
            show.settings.projector = display
            changed()
        }
    }

    // MARK: Editing

    /// Applies an edit to the sheet. Edit mode only: in show mode the sheet
    /// is locked and nothing changes. Returns whether anything did.
    ///
    /// - Parameter coalescing: For continuous controls such as sliders: an
    ///   edit with the same name as the last, within a second of it, joins
    ///   that edit's undo step rather than making its own.
    @discardableResult
    public func edit(_ actionName: String, coalescing: Bool = false, _ change: (inout Show) -> Void) -> Bool {
        guard mode == .edit else { return false }
        let before = show
        change(&show)
        guard show != before else { return false }
        let time = now()
        let merged = coalescing && lastCoalescing.map { $0.name == actionName && time - $0.at < Self.coalescingWindow } == true
        lastCoalescing = coalescing ? (actionName, time) : nil
        settle(after: before)
        if merged { onMergedEdit?() } else { onEdit?(before, actionName) }
        return true
    }

    /// Undo and redo: puts back the whole sheet as it was.
    public func restore(_ restored: Show) {
        let before = show
        show = restored
        settle(after: before)
    }

    private func settle(after before: Show) {
        playhead.reconcile(from: before, to: show)
        runner.geometry = show.settings.geometry
        if show.settings != before.settings { runner.settingsChanged(show.settings) }
        redrawLiveCue(comparedWith: before)
        preloadNext()
        changed()
    }

    /// An edit to the cue on stage shows at once, finished, as it looks
    /// after running; R runs it again from the start. A deleted cue comes
    /// off. A video is left playing, and R restarts it with any change.
    ///
    /// Only the cue itself, or a default its kind uses, counts. Geometry and
    /// text size relayout what is there; redrawing for them would rebuild an
    /// image's tiles on every tick of a slider and flash the projector.
    private func redrawLiveCue(comparedWith before: Show) {
        guard let id = runner.cue?.id else { return }
        guard let cue = show[id] else {
            runner.unload()
            return
        }
        // A transition only matters when the cue next arrives.
        let defaultsChanged = SettingKey.allCases.contains {
            $0.applies(to: cue.kind) && !SettingKey.transitions.contains($0)
                && $0.value(in: show.settings) != $0.value(in: before.settings)
        }
        var unchanged = before[id]
        unchanged?.transition = cue.transition
        guard cue.kind != .video, cue != unchanged || defaultsChanged else { return }
        runner.redraw(cue, defaults: show.settings, at: now())
        needsTicks(true)
    }

    /// Adds a cue after the one standing by, or at the end, numbered between
    /// its neighbours, and stands it by so it can be edited.
    @discardableResult
    public func addCue(_ kind: Cue.Kind) -> UUID? {
        // Every field starts empty; the editor hints at what goes in each.
        let cue: Cue
        switch kind {
        case .title: cue = Cue(content: .title(TitleContent()))
        case .image: cue = Cue(content: .image(ImageContent()))
        case .video: cue = Cue(content: .video(VideoContent()))
        case .blank: cue = Cue(content: .blank(BlankContent(text: "")))
        }
        let after = playhead.standby.flatMap { show.index(of: $0) }
        guard edit("Add \(kind.heading) Cue", { $0.insert(cue, after: after) }) else { return nil }
        playhead.standBy(cue.id)
        changed()
        return cue.id
    }

    public func updateCue(_ id: UUID, _ actionName: String, _ change: (inout Cue) -> Void) {
        edit(actionName) { show in
            guard let i = show.index(of: id) else { return }
            change(&show.cues[i])
        }
    }

    /// Moves a cue up or down the sheet. Its number goes with it.
    public func moveCue(_ id: UUID, by offset: Int) {
        edit("Move Cue") { show in
            guard let i = show.index(of: id) else { return }
            let j = max(0, min(show.cues.count - 1, i + offset))
            guard i != j else { return }
            show.cues.insert(show.cues.remove(at: i), at: j)
        }
    }

    public func deleteCue(_ id: UUID) {
        edit("Delete Cue") { $0.cues.removeAll { $0.id == id } }
    }

    /// 1, 2, 3... Meant for once, before tech. The console warns first.
    public func renumberAll() {
        edit("Renumber All") { $0.renumberAll() }
    }

    public func setProjector(_ state: ProjectorState) {
        guard state != projector else { return }
        projector = state
        changed()
    }

    /// After a crash: put `id` back up, finished, and stand by the next.
    public func resume(at id: UUID) {
        guard let fire = playhead.resume(at: id, in: show) else { return }
        perform(fire)
    }

    // MARK: The clock

    /// Called on every refresh of the display while a cue needs it.
    public func tick(at time: Double) {
        if let settled = runner.tick(at: time) {
            if let fire = playhead.liveCueSettled(settled, in: show) {
                perform(fire)
            } else if settled == playhead.live, case .whenFinished(let wait) = show[settled]?.continueMode, wait > 0 {
                // Finished: now the wait before the next cue.
                continueAt = (settled, time + Double(wait) / 1000)
            }
        }
        if let timed = continueAt, time >= timed.time {
            continueAt = nil
            if let fire = playhead.continueAfter(timed.cue, in: show) { perform(fire) }
        }
        // A timed continue keeps the clock going after the cue has settled.
        needsTicks(runner.needsTicks || continueAt != nil)
    }

    private func perform(_ fire: Playhead.Fire) {
        guard let cue = show[fire.cue] else { return }
        onFire?(cue)
        // Cleared first, so a problem the renderer reports while loading stays.
        message = nil
        switch fire.presentation {
        case .run:
            let time = now()
            runner.change(to: cue, defaults: show.settings, transition: cue.transitionIn(defaults: show.settings), at: time)
            // Timed from GO, whatever the cue's transition.
            if case .after(let ms) = cue.continueMode {
                continueAt = (cue.id, time + Double(ms) / 1000)
            } else {
                continueAt = nil
            }
        case .settled:
            // Back up after a crash: there, at once, and not counted as
            // settling, so nothing continues from it until GO.
            continueAt = nil
            runner.redraw(cue, defaults: show.settings, at: now())
        }
        if !runner.kinds.contains(cue.kind) {
            message = "Cue \(cue.number) is \(cue.kind == .image ? "an" : "a") \(cue.kind.name) cue, which this build doesn\u{2019}t draw yet, so the stage is black."
        }
        needsTicks(true)
        preloadNext()
        changed()
    }

    /// Puts a line in the console's status, or clears it.
    public func say(_ text: String?) {
        message = text
        preloadNext()
        changed()
    }

    /// Whatever could fire next gets its picture decoded now, while the
    /// current cue runs, rather than when GO is pressed.
    private func preloadNext() {
        for id in playhead.cuesThatMayFireNext(in: show) {
            if let cue = show[id] { runner.preload(cue, defaults: show.settings) }
        }
    }
}
