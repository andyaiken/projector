/// Splitting text that is too long for one line of the stage.
public enum TextLines {
    /// The most characters a line of stage text takes before it splits.
    public static let limit = 24

    /// The characters each line takes, as ranges over the text's
    /// characters: all of them when there are `limit` or fewer, otherwise
    /// split at the space nearest the middle, and again if a part is still
    /// too long. The space a line breaks at belongs to neither line. A text
    /// with no space to break at stays on one line, however long.
    public static func ranges(_ text: String, limit: Int = limit) -> [Range<Int>] {
        let characters = Array(text)
        func split(_ range: Range<Int>) -> [Range<Int>] {
            guard range.count > limit else { return range.isEmpty ? [] : [range] }
            let middle = Double(range.lowerBound + range.upperBound - 1) / 2
            let spaces = range.filter { characters[$0] == " " }
            guard let at = spaces.min(by: { abs(Double($0) - middle) < abs(Double($1) - middle) }) else { return [range] }
            return split(range.lowerBound..<at) + split(at + 1..<range.upperBound)
        }
        return split(0..<characters.count)
    }
}
