import Foundation

/// An opaque colour, eight bits a channel. Stored in show.json as `#rrggbb`.
public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = RGB(0, 0, 0)

    /// `#rrggbb`, lower case.
    public var hex: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }

    /// `#rgb` or `#rrggbb`, with or without the `#`.
    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded: String
        switch digits.count {
        case 3: expanded = digits.map { "\($0)\($0)" }.joined()
        case 6: expanded = String(digits)
        default: return nil
        }
        let v = UInt32(expanded, radix: 16)!
        self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }
}

extension RGB: Codable {
    /// Decoding is lenient, because show.json is meant to be repairable by
    /// hand: hex, `rgb()` or a CSS colour name all work, and anything else is
    /// black, as an unrecognised colour always has been.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = RGB(hex: text) ?? CSSColour.parse(text) ?? .black
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The two colours a title moves between, and the console's accent.
public enum Palette {
    /// Ciphertext, and the colour unflipped tiles are pulled toward.
    public static let slate = RGB(0x56, 0x63, 0x78)
    /// Settled text.
    public static let bone = RGB(0xF2, 0xEB, 0xDD)
    /// The ghost bars of expected English frequency, and the console's accent.
    public static let brass = RGB(0xC8, 0xA2, 0x4A)
}

/// Reads the CSS colours a hand-edited show.json may hold into `RGB`. Hex
/// (3, 4, 6 or 8 digits), `rgb()`/`rgba()` and the CSS named colours are
/// understood. Anything translucent is composited over black, since that is
/// what the stage shows behind it.
public enum CSSColour {
    public static func parse(_ text: String) -> RGB? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { return parseHex(s.dropFirst()) }
        if s.hasPrefix("rgb(") || s.hasPrefix("rgba("), s.hasSuffix(")") { return parseFunction(s) }
        if s == "transparent" { return .black }
        return namedColours[s].flatMap { RGB(hex: $0) }
    }

    private static func parseHex(_ digits: Substring) -> RGB? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        let chars = Array(digits)
        func channel(_ i: Int, width: Int) -> Double {
            let text = width == 1 ? String([chars[i], chars[i]]) : String(chars[i..<i + 2])
            return Double(UInt8(text, radix: 16)!)
        }
        switch chars.count {
        case 3, 4:
            let alpha = chars.count == 4 ? channel(3, width: 1) / 255 : 1
            return over(channel(0, width: 1), channel(1, width: 1), channel(2, width: 1), alpha)
        case 6, 8:
            let alpha = chars.count == 8 ? channel(6, width: 2) / 255 : 1
            return over(channel(0, width: 2), channel(2, width: 2), channel(4, width: 2), alpha)
        default:
            return nil
        }
    }

    // rgb(255, 0, 0)  rgba(255,0,0,0.5)  rgb(255 0 0 / 50%)  rgb(100%, 0%, 0%)
    private static func parseFunction(_ s: String) -> RGB? {
        guard let open = s.firstIndex(of: "(") else { return nil }
        let body = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let tokens = body
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
        guard tokens.count == 3 || tokens.count == 4 else { return nil }

        func value(_ token: Substring, percentOf scale: Double) -> Double? {
            if token.hasSuffix("%") {
                return Double(token.dropLast()).map { $0 / 100 * scale }
            }
            return Double(token)
        }
        var channels: [Double] = []
        for token in tokens.prefix(3) {
            guard let v = value(token, percentOf: 255) else { return nil }
            channels.append(min(max(v, 0), 255))
        }
        var alpha = 1.0
        if tokens.count == 4 {
            guard let a = value(tokens[3], percentOf: 1) else { return nil }
            alpha = min(max(a, 0), 1)
        }
        return over(channels[0], channels[1], channels[2], alpha)
    }

    private static func over(_ r: Double, _ g: Double, _ b: Double, _ alpha: Double) -> RGB {
        func c(_ v: Double) -> UInt8 { UInt8(clamping: roundHalfUp(v * alpha)) }
        return RGB(c(r), c(g), c(b))
    }

    /// CSS Color Module Level 4 named colours.
    static let namedColours: [String: String] = [
        "aliceblue": "f0f8ff", "antiquewhite": "faebd7", "aqua": "00ffff", "aquamarine": "7fffd4",
        "azure": "f0ffff", "beige": "f5f5dc", "bisque": "ffe4c4", "black": "000000",
        "blanchedalmond": "ffebcd", "blue": "0000ff", "blueviolet": "8a2be2", "brown": "a52a2a",
        "burlywood": "deb887", "cadetblue": "5f9ea0", "chartreuse": "7fff00", "chocolate": "d2691e",
        "coral": "ff7f50", "cornflowerblue": "6495ed", "cornsilk": "fff8dc", "crimson": "dc143c",
        "cyan": "00ffff", "darkblue": "00008b", "darkcyan": "008b8b", "darkgoldenrod": "b8860b",
        "darkgray": "a9a9a9", "darkgreen": "006400", "darkgrey": "a9a9a9", "darkkhaki": "bdb76b",
        "darkmagenta": "8b008b", "darkolivegreen": "556b2f", "darkorange": "ff8c00", "darkorchid": "9932cc",
        "darkred": "8b0000", "darksalmon": "e9967a", "darkseagreen": "8fbc8f", "darkslateblue": "483d8b",
        "darkslategray": "2f4f4f", "darkslategrey": "2f4f4f", "darkturquoise": "00ced1", "darkviolet": "9400d3",
        "deeppink": "ff1493", "deepskyblue": "00bfff", "dimgray": "696969", "dimgrey": "696969",
        "dodgerblue": "1e90ff", "firebrick": "b22222", "floralwhite": "fffaf0", "forestgreen": "228b22",
        "fuchsia": "ff00ff", "gainsboro": "dcdcdc", "ghostwhite": "f8f8ff", "gold": "ffd700",
        "goldenrod": "daa520", "gray": "808080", "green": "008000", "greenyellow": "adff2f",
        "grey": "808080", "honeydew": "f0fff0", "hotpink": "ff69b4", "indianred": "cd5c5c",
        "indigo": "4b0082", "ivory": "fffff0", "khaki": "f0e68c", "lavender": "e6e6fa",
        "lavenderblush": "fff0f5", "lawngreen": "7cfc00", "lemonchiffon": "fffacd", "lightblue": "add8e6",
        "lightcoral": "f08080", "lightcyan": "e0ffff", "lightgoldenrodyellow": "fafad2", "lightgray": "d3d3d3",
        "lightgreen": "90ee90", "lightgrey": "d3d3d3", "lightpink": "ffb6c1", "lightsalmon": "ffa07a",
        "lightseagreen": "20b2aa", "lightskyblue": "87cefa", "lightslategray": "778899", "lightslategrey": "778899",
        "lightsteelblue": "b0c4de", "lightyellow": "ffffe0", "lime": "00ff00", "limegreen": "32cd32",
        "linen": "faf0e6", "magenta": "ff00ff", "maroon": "800000", "mediumaquamarine": "66cdaa",
        "mediumblue": "0000cd", "mediumorchid": "ba55d3", "mediumpurple": "9370db", "mediumseagreen": "3cb371",
        "mediumslateblue": "7b68ee", "mediumspringgreen": "00fa9a", "mediumturquoise": "48d1cc", "mediumvioletred": "c71585",
        "midnightblue": "191970", "mintcream": "f5fffa", "mistyrose": "ffe4e1", "moccasin": "ffe4b5",
        "navajowhite": "ffdead", "navy": "000080", "oldlace": "fdf5e6", "olive": "808000",
        "olivedrab": "6b8e23", "orange": "ffa500", "orangered": "ff4500", "orchid": "da70d6",
        "palegoldenrod": "eee8aa", "palegreen": "98fb98", "paleturquoise": "afeeee", "palevioletred": "db7093",
        "papayawhip": "ffefd5", "peachpuff": "ffdab9", "peru": "cd853f", "pink": "ffc0cb",
        "plum": "dda0dd", "powderblue": "b0e0e6", "purple": "800080", "rebeccapurple": "663399",
        "red": "ff0000", "rosybrown": "bc8f8f", "royalblue": "4169e1", "saddlebrown": "8b4513",
        "salmon": "fa8072", "sandybrown": "f4a460", "seagreen": "2e8b57", "seashell": "fff5ee",
        "sienna": "a0522d", "silver": "c0c0c0", "skyblue": "87ceeb", "slateblue": "6a5acd",
        "slategray": "708090", "slategrey": "708090", "snow": "fffafa", "springgreen": "00ff7f",
        "steelblue": "4682b4", "tan": "d2b48c", "teal": "008080", "thistle": "d8bfd8",
        "tomato": "ff6347", "turquoise": "40e0d0", "violet": "ee82ee", "wheat": "f5deb3",
        "white": "ffffff", "whitesmoke": "f5f5f5", "yellow": "ffff00", "yellowgreen": "9acd32",
    ]
}
