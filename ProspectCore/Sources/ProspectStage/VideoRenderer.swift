import AVFoundation
import ProspectCore
import QuartzCore

/// Video cues: moving footage. Unlike the other cue types a video doesn't
/// resolve over a frame count, it plays, on AVPlayer's own clock; `frame`
/// only polls it, for the readouts and to say when it has ended.
///
/// It is also the one renderer that paints surfaces differently. The live
/// surface gets the picture. The console preview gets a poster frame with
/// elapsed and remaining time: at preview size a moving picture tells the
/// operator nothing, and a countdown tells them when to stand by.
///
/// Audio is always muted. Sound is another operator on another machine, and
/// a switch that let this play into the room would be the switch left on.
@MainActor
public final class VideoRenderer: CueRenderer, ReportsProblems, ArmsCues {
    public let isInstant = true
    public var onProblem: ((String) -> Void)?
    public var onArmStateChange: (() -> Void)?

    /// Players kept ready: what might fire next, what is on stage, and what
    /// was on stage last, so R restarts at once.
    static let keep = 4

    private let media: (String) -> URL?
    private var clips: [UUID: Clip] = [:]
    private(set) var current: Clip?
    private var started = false
    private var trees: [ObjectIdentifier: Tree] = [:]

    public init(media: @escaping (String) -> URL? = { _ in nil }) {
        self.media = media
    }

    /// One clip's player, armed or playing.
    final class Clip {
        let cue: Cue
        let content: VideoContent
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var item: AVPlayerItem?
        var duration = CMTime.zero
        var poster: CGImage?
        var state = ArmState.arming
        var reachedEnd = false
        var playWhenArmed = false
        var lastUsed = Date()
        var endObserver: NSObjectProtocol?

        init(cue: Cue, content: VideoContent) {
            self.cue = cue
            self.content = content
            player.isMuted = true
            player.volume = 0
            // A held clip freezes on its last frame rather than emptying.
            player.actionAtItemEnd = .pause
        }

        var elapsed: CMTime { player.currentTime() }

        func matches(_ other: VideoContent) -> Bool {
            other.src == content.src && other.atEnd == content.atEnd
        }
    }

    /// One surface's layers: a player layer for each clip on the live
    /// surface, so an armed clip's first frame is already waiting there; on
    /// the preview, a poster and a readout.
    final class Tree {
        let surface: SurfaceLayer
        let root = StillLayer()
        var players: [UUID: StillPlayerLayer] = [:]
        let poster = StillLayer()
        let strip = StillLayer()
        let readout = TextLayer()

        init(surface: SurfaceLayer) {
            self.surface = surface
            root.isHidden = true
            root.backgroundColor = CGColor(gray: 0, alpha: 1)
            if surface.role == .preview {
                poster.contentsGravity = .resizeAspect
                strip.backgroundColor = CGColor(gray: 0, alpha: 0.6)
                root.addSublayer(poster)
                root.addSublayer(strip)
                strip.addSublayer(readout)
            }
        }

        var isLive: Bool { surface.role == .live }
    }

    func tree(for surface: SurfaceLayer) -> Tree? {
        trees[ObjectIdentifier(surface)]
    }

    // MARK: ArmsCues

    public func armState(for cue: UUID) -> ArmState? {
        clips[cue]?.state
    }

    // MARK: CueRenderer

    public func mount(on surface: SurfaceLayer) {
        let tree = Tree(surface: surface)
        trees[ObjectIdentifier(surface)] = tree
        surface.inset.addSublayer(tree.root)
        if tree.isLive {
            for clip in clips.values { addPlayerLayer(for: clip, to: tree) }
        }
        fit(surface)
        show(current, on: tree)
    }

    public func unmount(from surface: SurfaceLayer) {
        trees.removeValue(forKey: ObjectIdentifier(surface))?.root.removeFromSuperlayer()
    }

    public func setVisible(_ visible: Bool, on surface: SurfaceLayer) {
        tree(for: surface)?.root.isHidden = !visible
    }

    /// Stops whatever was playing. It goes back to the start and stays
    /// armed, so running it again is instant.
    public func clear(_ surface: SurfaceLayer) {
        if let clip = current {
            current = nil
            clip.player.pause()
            clip.playWhenArmed = false
            clip.reachedEnd = false
            clip.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        started = false
        for tree in trees.values { show(nil, on: tree) }
    }

    public func prepare(_ cue: Cue, defaults: ShowSettings) {
        guard case .video(let content) = cue.content else { return }
        let clip = arm(cue, content)
        clip.lastUsed = Date()
        current = clip
        started = false
        for tree in trees.values { show(clip, on: tree) }
        // Said again as it fires, not only when it was armed: this is when
        // the operator needs to know the stage has gone black.
        if case .failed(let message) = clip.state { onProblem?(message) }
    }

    public func frame(_ f: Int) -> Bool {
        guard let clip = current else { return true }
        if !started {
            started = true
            if f >= StageRunner.settledFrame { putUpFinished(clip) } else { play(clip) }
        }
        for tree in trees.values where !tree.isLive { updateReadout(tree, clip) }
        if case .failed = clip.state { return true }
        return clip.content.atEnd == .loop ? false : clip.reachedEnd
    }

    public func fit(_ surface: SurfaceLayer) {
        guard let tree = tree(for: surface) else { return }
        let bounds = surface.inset.bounds
        tree.root.frame = bounds
        for layer in tree.players.values { layer.frame = bounds }
        guard !tree.isLive else { return }
        tree.poster.frame = bounds
        let size = max(9, min(bounds.height * 0.07, 15))
        let height = (size * 1.9).rounded()
        tree.strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        tree.readout.frame = tree.strip.bounds.insetBy(dx: size * 0.8, dy: 0)
        tree.readout.contentsScale = surface.contentsScale
        tree.readout.baseline = (height - size) / 2 + size * 0.2
        if let clip = current { updateReadout(tree, clip) }
    }

    /// Arming: the cue that may fire next is loaded, prerolled and waiting
    /// at its first frame before GO.
    public func preload(_ cue: Cue, defaults: ShowSettings) {
        guard case .video(let content) = cue.content else { return }
        arm(cue, content).lastUsed = Date()
    }

    // MARK: Arming

    @discardableResult
    private func arm(_ cue: Cue, _ content: VideoContent) -> Clip {
        if let clip = clips[cue.id], clip.matches(content) { return clip }
        if let stale = clips[cue.id] { discard(stale) }

        let clip = Clip(cue: cue, content: content)
        clips[cue.id] = clip
        evictBeyondLimit()
        for tree in trees.values where tree.isLive { addPlayerLayer(for: clip, to: tree) }

        guard !content.src.isEmpty, let url = media(content.src), FileManager.default.isReadableFile(atPath: url.path) else {
            fail(clip, "Cue \(cue.number)\u{2019}s clip\(content.src.isEmpty ? "" : ", \(Self.name(content.src)),") is missing from the show, so it will go to black.")
            return clip
        }
        Task { await load(clip, from: url) }
        onArmStateChange?()
        return clip
    }

    private func load(_ clip: Clip, from url: URL) async {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
            clip.duration = try await asset.load(.duration)
            let item = AVPlayerItem(asset: asset)
            clip.item = item
            if clip.content.atEnd == .loop {
                clip.looper = AVPlayerLooper(player: clip.player, templateItem: item)
            } else {
                clip.player.insert(item, after: nil)
                // Looked up again by cue and item, since a clip can be replaced.
                let cue = clip.cue.id, itemID = ObjectIdentifier(item)
                clip.endObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let clip = self.clips[cue], clip.item.map(ObjectIdentifier.init) == itemID else { return }
                        self.reachedEnd(clip)
                    }
                }
            }
            // Ready to play, then prerolled so the first frames are decoded.
            while clip.player.status == .unknown || clip.player.currentItem?.status ?? .unknown == .unknown {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard clip.player.status == .readyToPlay, clip.player.currentItem?.status == .readyToPlay else {
                throw clip.player.currentItem?.error ?? clip.player.error ?? CocoaError(.fileReadCorruptFile)
            }
            if clip.player.rate == 0 { _ = await clip.player.preroll(atRate: 1) }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 540)
            clip.poster = try? await generator.image(at: .zero).image

            guard clips[clip.cue.id] === clip else { return }
            clip.state = .armed
            for tree in trees.values where !tree.isLive && current === clip { show(clip, on: tree) }
            if clip.playWhenArmed { clip.player.play() }
            onArmStateChange?()
        } catch {
            fail(clip, "Cue \(clip.cue.number)\u{2019}s clip, \(Self.name(clip.content.src)), couldn\u{2019}t be played, so it will go to black.")
        }
    }

    private func fail(_ clip: Clip, _ message: String) {
        clip.state = .failed(message)
        clip.reachedEnd = true
        for tree in trees.values { tree.players[clip.cue.id]?.opacity = 0 }
        onProblem?(message)
        onArmStateChange?()
    }

    private static func name(_ src: String) -> String {
        (src as NSString).lastPathComponent
    }

    // MARK: Playing

    private func play(_ clip: Clip) {
        clip.reachedEnd = false
        switch clip.state {
        case .armed: clip.player.play()
        case .arming: clip.playWhenArmed = true
        case .failed: break
        }
    }

    /// As on resuming after a crash: a held clip on its last frame, a black
    /// one black, a looping one looping.
    private func putUpFinished(_ clip: Clip) {
        switch clip.content.atEnd {
        case .loop:
            play(clip)
        case .black:
            reachedEnd(clip)
        case .hold:
            clip.reachedEnd = true
            if clip.duration > .zero {
                clip.player.seek(to: clip.duration, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func reachedEnd(_ clip: Clip) {
        clip.reachedEnd = true
        guard clip.content.atEnd == .black, current === clip else { return }
        // Cut to black, as a blank cue would.
        for tree in trees.values { tree.players[clip.cue.id]?.opacity = 0 }
    }

    // MARK: Layers

    private func addPlayerLayer(for clip: Clip, to tree: Tree) {
        guard tree.players[clip.cue.id] == nil else { return }
        let layer = StillPlayerLayer()
        layer.player = clip.player
        layer.videoGravity = .resizeAspect
        layer.frame = tree.root.bounds
        // Transparent rather than hidden, so it stays in the render tree and
        // has its first frame ready when GO makes it visible.
        layer.opacity = 0
        tree.players[clip.cue.id] = layer
        tree.root.addSublayer(layer)
    }

    /// Shows `clip` on a surface, or nothing.
    private func show(_ clip: Clip?, on tree: Tree) {
        if tree.isLive {
            for (id, layer) in tree.players {
                let visible = id == clip?.cue.id && clip.map(isShowable) == true
                layer.opacity = visible ? 1 : 0
            }
        } else {
            tree.poster.contents = clip?.poster
            if let clip { updateReadout(tree, clip) } else { tree.readout.runs = [] }
        }
    }

    private func isShowable(_ clip: Clip) -> Bool {
        if case .failed = clip.state { return false }
        return !(clip.reachedEnd && clip.content.atEnd == .black)
    }

    /// Elapsed and remaining, for the operator, on the preview only.
    private func updateReadout(_ tree: Tree, _ clip: Clip) {
        let size = max(9, min(tree.surface.inset.bounds.height * 0.07, 15))
        let font = StageFont.text(size: size)
        let text: String
        switch clip.state {
        case .failed:
            text = "NO CLIP \u{2014} BLACK"
        case .arming:
            text = "LOADING \u{2014} NOT ARMED"
        case .armed:
            let duration = clip.duration.seconds.isFinite ? clip.duration.seconds : 0
            var elapsed = max(0, clip.elapsed.seconds.isFinite ? clip.elapsed.seconds : 0)
            if clip.content.atEnd == .loop, duration > 0 { elapsed = elapsed.truncatingRemainder(dividingBy: duration) }
            // Remaining rounds up, as a countdown should: it reads 0:00 only
            // when the picture has actually finished.
            let remaining = max(0, duration - elapsed).rounded(.up)
            switch (clip.reachedEnd && started, clip.content.atEnd) {
            case (true, .hold): text = "ENDED \u{2014} HOLDING LAST FRAME"
            case (true, .black): text = "ENDED \u{2014} BLACK"
            case (_, .loop): text = "\(Self.clock(elapsed)) of \(Self.clock(duration)) \u{2014} LOOPING"
            default: text = "\(Self.clock(elapsed))   \(Self.clock(remaining)) LEFT   THEN \(clip.content.atEnd == .black ? "BLACK" : "HOLDS")"
            }
        }
        tree.readout.runs = [TextRun(text: text, font: font, colour: Palette.bone.cgColor(alpha: 0.9), x: 0)]
    }

    /// m:ss.
    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: Housekeeping

    private func evictBeyondLimit() {
        let spare = clips.values.filter { $0 !== current }.sorted { $0.lastUsed < $1.lastUsed }
        for clip in spare.prefix(max(0, clips.count - Self.keep)) { discard(clip) }
    }

    private func discard(_ clip: Clip) {
        clip.player.pause()
        clip.looper?.disableLooping()
        clip.player.removeAllItems()
        if let observer = clip.endObserver { NotificationCenter.default.removeObserver(observer) }
        clips.removeValue(forKey: clip.cue.id)
        for tree in trees.values { tree.players.removeValue(forKey: clip.cue.id)?.removeFromSuperlayer() }
    }
}

/// A player layer with no implicit animations: shown and hidden on the cut.
final class StillPlayerLayer: AVPlayerLayer {
    override func action(forKey event: String) -> (any CAAction)? {
        nil
    }
}
