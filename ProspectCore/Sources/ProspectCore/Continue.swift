import Foundation

/// What happens after a cue: whether the show moves on to the next cue in
/// the sheet by itself, and when.
public enum ContinueMode: Equatable, Sendable {
    /// Only GO fires the next cue.
    case whenCued
    /// The next cue fires this long after this one fires.
    case after(ms: Int)
    /// The next cue fires this long after this one finishes: a reveal
    /// settles, a picture lands, a clip ends. Only for cues that take time;
    /// see `finishes`.
    case whenFinished(waitMs: Int)

    /// Finished, and straight on.
    public static let whenFinished = ContinueMode.whenFinished(waitMs: 0)

    /// Whether the next cue may fire without GO.
    public var continues: Bool { self != .whenCued }

    /// Whether the next cue fires the moment this one finishes, or fires,
    /// with no wait.
    public var isImmediate: Bool {
        self == .whenFinished(waitMs: 0) || self == .after(ms: 0)
    }

    /// The longest wait the editor allows: an hour.
    public static let longest = 3_600_000

    /// How it reads on the printed sheet.
    public var summary: String {
        switch self {
        case .whenCued: "when cued"
        case .after(0): "at once"
        case .after(let ms): "after " + Self.seconds(ms) + " s"
        case .whenFinished(0): "when finished"
        case .whenFinished(let ms): Self.seconds(ms) + " s after it finishes"
        }
    }

    /// Whole seconds plainly, a fraction to a tenth.
    public static func seconds(_ ms: Int) -> String {
        fixedDecimal(Double(ms) / 1000, digits: ms % 1000 == 0 ? 0 : 1)
    }
}

extension Cue {
    /// Whether the cue takes time, so that "when finished" means something.
    /// A blank is instant, and a looping clip never ends.
    public var finishes: Bool {
        switch content {
        case .title, .image: true
        case .video(let v): v.atEnd != .loop
        case .blank: false
        }
    }
}

/// In show.json, absent for when cued; otherwise `{"after": 5}`, timed from
/// the cue firing, or `{"finished": 2}`, timed from it finishing; seconds.
extension ContinueMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case after, finished
    }

    public init(from decoder: Decoder) throws {
        func ms(_ seconds: Double) -> Int {
            Swift.min(Swift.max(0, Int((seconds * 1000).rounded())), Self.longest)
        }
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            if let seconds = try c.decodeIfPresent(Double.self, forKey: .finished) {
                self = .whenFinished(waitMs: ms(seconds))
            } else if let seconds = try c.decodeIfPresent(Double.self, forKey: .after) {
                self = .after(ms: ms(seconds))
            } else {
                self = .whenCued
            }
            return
        }
        // Earlier shorthand, still read: a bare number of seconds after
        // firing, or "finished".
        let c = try decoder.singleValueContainer()
        if let seconds = try? c.decode(Double.self) {
            self = .after(ms: ms(seconds))
        } else {
            self = (try? c.decode(String.self)) == "finished" ? .whenFinished : .whenCued
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .whenCued: break
        case .after(let ms): try c.encode(Double(ms) / 1000, forKey: .after)
        case .whenFinished(let ms): try c.encode(Double(ms) / 1000, forKey: .finished)
        }
    }
}
