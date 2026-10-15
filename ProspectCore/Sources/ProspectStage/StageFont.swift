import AppKit
import CoreText
import ProspectCore

/// The type the stage is set in: the system's SF Mono. Titles are medium
/// weight, everything else regular.
///
/// Main actor only: AppKit's font lookup isn't safe to call from several
/// threads at once, and under contention it hands back a different face.
@MainActor
public enum StageFont {
    public static func title(size: CGFloat) -> CTFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .medium) as CTFont
    }

    public static func text(size: CGFloat) -> CTFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
    }

    /// Everything a title can show while it travels: the 45-glyph ring and
    /// the open box drawn for an unsettled space. If any of these were
    /// missing, a fallback font of a different width would make the line
    /// shiver as glyphs rotate.
    public static let revealCharacters: [Character] = Cipher.ring + [Cipher.spaceMark]

    /// Everything else drawn on stage around a title: the readouts and the
    /// histogram's axis.
    public static let readoutCharacters: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789/.\u{2014}\u{03C7}\u{00B2} ")

    public struct Coverage: Equatable {
        /// Characters the font has no glyph of its own for.
        public var missing: [Character]
        /// Every distinct advance width among the characters it does have.
        public var advances: Set<CGFloat>
    }

    /// Which of `characters` the font draws itself, and at what widths.
    public static func coverage(of characters: [Character], in font: CTFont) -> Coverage {
        var missing: [Character] = []
        var advances = Set<CGFloat>()
        for c in characters {
            var units = Array(String(c).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard units.count == 1, CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1) else {
                missing.append(c)
                continue
            }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
            advances.insert(advance.width)
        }
        return Coverage(missing: missing, advances: advances)
    }

    /// The advance shared by every glyph of a monospaced font.
    static func advance(of font: CTFont) -> CGFloat {
        var units = Array("M".utf16)
        var glyph = CGGlyph(0)
        var advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &units, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }

    /// CSS `line-height: normal`: ascent, descent and line gap.
    static func normalLineHeight(of font: CTFont) -> CGFloat {
        CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }
}

extension RGB {
    public var cgColor: CGColor { cgColor(alpha: 1) }

    public func cgColor(alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
    }
}
