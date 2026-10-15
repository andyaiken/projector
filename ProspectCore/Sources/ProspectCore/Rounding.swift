import Foundation

// Two places where Prospect rounds differently from Swift's defaults. Both
// matter: timings and readouts must come out the same every time, and the
// tests compare against recorded values exactly.

/// Exact halves go up, toward positive infinity. Swift's `rounded()` sends
/// negative halves the other way.
func roundHalfUp(_ x: Double) -> Int {
    let floor = x.rounded(.down)
    return Int(x - floor >= 0.5 ? floor + 1 : floor)
}

/// A number to 0 to 3 decimal places. Exact ties round up (0.25 to one
/// place is `"0.3"`), where `String(format: "%.1f")` rounds them to even and
/// gives `"0.2"`.
public func fixedDecimal(_ x: Double, digits: Int) -> String {
    precondition(x.isFinite && abs(x) < 1e21 && (0...3).contains(digits))

    // Sixty places are the exact binary value for anything at or above 2^-8,
    // and nothing smaller can sit on a tie at three places or fewer.
    let exact = String(format: "%.60f", abs(x))
    let parts = exact.split(separator: ".", maxSplits: 1)
    var kept = Array(parts[0] + parts[1].prefix(digits))
    let roundsUp = parts[1].dropFirst(digits).first.map { $0 >= "5" } ?? false

    if roundsUp {
        var i = kept.count - 1
        while i >= 0 {
            if kept[i] == "9" {
                kept[i] = "0"
                i -= 1
            } else {
                kept[i] = Character(String(kept[i].wholeNumberValue! + 1))
                break
            }
        }
        if i < 0 { kept.insert("1", at: 0) }
    }

    let whole = String(kept.dropLast(digits))
    let fraction = String(kept.suffix(digits))
    let sign = x < 0 ? "-" : ""
    return digits == 0 ? sign + whole : sign + whole + "." + fraction
}
