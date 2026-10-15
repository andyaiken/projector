import Foundation

// Cue numbers are identifiers the DSM writes in the book. Nothing here ever
// changes a number except `renumberAll`, which is meant to be used once,
// before tech.

extension Show {
    /// The first cue with this number. Numbers compare trimmed and
    /// case-insensitive, otherwise exact, so `4.5`
    /// and `4.50` are different cues.
    public func index(ofNumber number: String) -> Int? {
        let wanted = Self.normalised(number)
        return cues.firstIndex { Self.normalised($0.number) == wanted }
    }

    /// Numbers used by more than one cue, with the cues using them, in sheet
    /// order. A called number must be unambiguous, so these are flagged.
    public var duplicateNumbers: [(number: String, cues: [UUID])] {
        var seen: [String: [UUID]] = [:]
        var order: [String] = []
        for cue in cues {
            let key = Self.normalised(cue.number)
            guard !key.isEmpty else { continue }
            if seen[key] == nil { order.append(key) }
            seen[key, default: []].append(cue.id)
        }
        return order.compactMap { key in
            let ids = seen[key]!
            guard ids.count > 1 else { return nil }
            return (self[ids[0]]!.number.trimmingCharacters(in: .whitespacesAndNewlines), ids)
        }
    }

    /// The number Add Cue gives a cue inserted after `index` (nil for none
    /// selected). Nil means leave it empty for the operator to type.
    public func numberForInsertion(after index: Int?) -> String? {
        guard let index, index < cues.count - 1 else {
            return String(Int(highestNumber().rounded(.down)) + 1)
        }
        return Self.number(between: cues[index].number, and: cues[index + 1].number)
    }

    /// Inserts `cue` after `index` (at the end for nil), numbered by
    /// `numberForInsertion`. Returns where it went.
    @discardableResult
    public mutating func insert(_ cue: Cue, after index: Int?) -> Int {
        var cue = cue
        cue.number = numberForInsertion(after: index) ?? ""
        let position = index.map { $0 + 1 } ?? cues.count
        cues.insert(cue, at: position)
        return position
    }

    /// 1, 2, 3... in running order. The book will need rewriting to match.
    public mutating func renumberAll() {
        for i in cues.indices { cues[i].number = String(i + 1) }
    }

    /// The shortest decimal strictly between two plain numbers, as close to
    /// the midpoint as that allows, ties going up: 4 and 5 give 4.5, 4 and
    /// 4.5 give 4.3, 9 and 9.1 give 9.05. Nil when either isn't a plain
    /// number (`P12`) or they aren't in ascending order.
    public static func number(between a: String, and b: String) -> String? {
        guard let lo = PlainDecimal(a), let hi = PlainDecimal(b) else { return nil }
        let scale = max(lo.scale, hi.scale) + 1
        let A = lo.units * pow10(scale - lo.scale)
        let B = hi.units * pow10(scale - hi.scale)
        guard A < B else { return nil }

        let twiceMid = A + B
        for places in 0...scale {
            let unit = pow10(scale - places)
            let first = A / unit + 1         // smallest multiple of unit above A
            let last = (B - 1) / unit        // largest multiple of unit below B
            guard first <= last else { continue }
            func distance(_ k: Int) -> Int { abs(2 * k * unit - twiceMid) }
            let below = min(max(twiceMid / (2 * unit), first), last)
            let above = min(max(below + 1, first), last)
            let k = distance(above) <= distance(below) ? above : below
            return PlainDecimal(units: k, scale: places).text
        }
        return nil
    }

    static func normalised(_ number: String) -> String {
        number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The highest number in the sheet, read as `parseFloat` reads it: the
    /// leading numeric part, so `12a` is 12 and `P12` doesn't count.
    func highestNumber() -> Double {
        cues.compactMap { Self.leadingNumber($0.number) }.max().map { max($0, 0) } ?? 0
    }

    static func leadingNumber(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.prefixMatch(of: /[+-]?(\d+(\.\d*)?|\.\d+)/) else { return nil }
        return Double(match.output.0)
    }
}

/// A number with only digits and at most one decimal point, held exactly as
/// an integer count of `10^-scale`.
private struct PlainDecimal {
    let units: Int
    let scale: Int

    init(units: Int, scale: Int) {
        self.units = units
        self.scale = scale
    }

    init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = s.wholeMatch(of: /(\d+)(?:\.(\d+))?/) else { return nil }
        let whole = match.output.1
        let fraction = match.output.2 ?? ""
        // Keep well inside Int once scaled up by one more place.
        guard whole.count + fraction.count <= 15, let units = Int(whole + fraction) else { return nil }
        self.units = units
        scale = fraction.count
    }

    var text: String {
        guard scale > 0 else { return String(units) }
        let p = pow10(scale)
        let fraction = String(units % p)
        return "\(units / p)." + String(repeating: "0", count: scale - fraction.count) + fraction
    }
}

private func pow10(_ n: Int) -> Int {
    (0..<n).reduce(1) { r, _ in r * 10 }
}
