import Foundation

/// Something wrong with the sheet that the console should flag. None of them
/// stops the show; each is a cue that will not do what the book expects.
public enum SheetIssue: Equatable, Sendable {
    case duplicateNumber(String, cues: [UUID])
    case missingNumber(cue: UUID)
    /// The last cue continues, but there is nothing after it.
    case continuesPastEnd(cue: UUID)
    /// A looping clip set to continue when finished, which it never is.
    case neverFinishes(cue: UUID)
    case videoWithoutClip(cue: UUID)
    /// A decryption with nothing to decrypt puts nothing on stage.
    case decryptionWithoutPlace(cue: UUID)
    /// Without a key, the text scrambles but was never encrypted.
    case decryptionWithoutKey(cue: UUID)

    /// The cues the console highlights for this issue.
    public var cues: [UUID] {
        switch self {
        case .duplicateNumber(_, let cues): cues
        case .missingNumber(let cue), .continuesPastEnd(let cue), .neverFinishes(let cue), .videoWithoutClip(let cue),
             .decryptionWithoutPlace(let cue), .decryptionWithoutKey(let cue): [cue]
        }
    }
}

extension Show {
    /// Every problem with the sheet, in sheet order. Messages name cues by
    /// number, never by position.
    public var issues: [SheetIssue] {
        var issues = duplicateNumbers.map { SheetIssue.duplicateNumber($0.number, cues: $0.cues) }
        for (i, cue) in cues.enumerated() {
            if Self.normalised(cue.number).isEmpty {
                issues.append(.missingNumber(cue: cue.id))
            }
            if cue.continueMode.continues, i == cues.count - 1 {
                issues.append(.continuesPastEnd(cue: cue.id))
            } else if case .whenFinished = cue.continueMode, case .video(let v) = cue.content, v.atEnd == .loop {
                issues.append(.neverFinishes(cue: cue.id))
            }
            if case .video(let v) = cue.content, v.src.isEmpty {
                issues.append(.videoWithoutClip(cue: cue.id))
            }
            if case .title(let t) = cue.content {
                if t.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append(.decryptionWithoutPlace(cue: cue.id))
                } else if t.key.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append(.decryptionWithoutKey(cue: cue.id))
                }
            }
        }
        return issues
    }

    /// What the console says about an issue.
    public func message(for issue: SheetIssue) -> String {
        func name(_ id: UUID) -> String {
            guard let cue = self[id] else { return "A cue" }
            let number = cue.number.trimmingCharacters(in: .whitespacesAndNewlines)
            guard number.isEmpty else { return "Cue \(number)" }
            return cue.text.isEmpty ? "An unnumbered \(cue.kind.name) cue" : "The \(cue.kind.name) cue \u{201C}\(cue.text)\u{201D}"
        }
        switch issue {
        case .duplicateNumber(let number, let ids):
            return "Cue number \(number) is used \(ids.count) times. A called number must be unambiguous."
        case .missingNumber(let id):
            return "\(name(id)) has no number."
        case .continuesPastEnd(let id):
            return "\(name(id)) is set to continue, but it is the last cue, so there is nothing to continue to."
        case .neverFinishes(let id):
            return "\(name(id)) loops and never finishes, so the show won\u{2019}t continue from it by itself."
        case .videoWithoutClip(let id):
            return "\(name(id)) has no clip, and will go to black."
        case .decryptionWithoutPlace(let id):
            return "\(name(id)) has no text, so nothing will appear."
        case .decryptionWithoutKey(let id):
            return "\(name(id)) has no key, so its text isn\u{2019}t encrypted."
        }
    }
}
