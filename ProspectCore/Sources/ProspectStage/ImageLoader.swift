import CoreText
import Foundation
import ImageIO
import ProspectCore

/// Where an image cue's picture comes from.
public enum ImageSource: Hashable, Sendable {
    /// No picture: the cue's label, on black.
    case label(String)
    /// A file in the show.
    case file(URL)
}

/// Decodes pictures off the main thread and keeps them, so a cue never
/// stalls the clock while its image loads, and a preloaded cue fires with
/// its picture already in hand.
///
/// Files are decoded straight down to the size the stage needs, so a
/// 48-megapixel photograph never sits in memory at full size. Decoded
/// pictures are kept up to a memory budget, least recently used going first;
/// one on stage is held by its tiles regardless, so dropping it from here
/// only means decoding it again next time.
@MainActor
public final class ImageLoader {
    public struct Failure: Error, Sendable {
        public enum Reason: Sendable {
            /// Not there, or not readable.
            case missing
            /// There, but not an image ImageIO can decode.
            case undecodable
        }

        public let reason: Reason
    }

    public typealias Completion = @MainActor (Result<CGImage, Failure>) -> Void

    private struct Key: Hashable {
        let source: ImageSource
        let maxPixels: Int
    }

    private var cache: [Key: CGImage] = [:]
    private var lastUsed: [Key: UInt64] = [:]
    private var useCount: UInt64 = 0
    private var waiting: [Key: [Completion]] = [:]

    /// The most decoded pictures may take, in bytes.
    public let budget: Int
    /// What they take now.
    public private(set) var cachedBytes = 0
    public var cachedCount: Int { cache.count }
    // Created here on the main thread; Core Text fonts are safe to use from
    // any thread once made.
    nonisolated(unsafe) private let labelFont: CTFont

    /// - Parameter budget: 512 MB by default: dozens of pictures at a
    ///   projector's size.
    public init(budget: Int = 512 * 1024 * 1024) {
        self.budget = budget
        labelFont = StageFont.title(size: 26)
    }

    /// The picture if it is already decoded at this size.
    public func cached(_ source: ImageSource, maxPixels: Int) -> CGImage? {
        let key = Key(source: source, maxPixels: maxPixels)
        guard let image = cache[key] else { return nil }
        touch(key)
        return image
    }

    private func touch(_ key: Key) {
        useCount += 1
        lastUsed[key] = useCount
    }

    private func store(_ image: CGImage, for key: Key) {
        if let old = cache[key] { cachedBytes -= Self.cost(of: old) }
        cache[key] = image
        cachedBytes += Self.cost(of: image)
        touch(key)
        // Never the picture just stored, even if it alone is over budget.
        while cachedBytes > budget, cache.count > 1,
              let oldest = lastUsed.filter({ $0.key != key }).min(by: { $0.value < $1.value })?.key {
            if let image = cache.removeValue(forKey: oldest) { cachedBytes -= Self.cost(of: image) }
            lastUsed.removeValue(forKey: oldest)
        }
    }

    private static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    /// Calls `completion` with the picture: straight away if it is already
    /// decoded, otherwise once a background decode finishes.
    ///
    /// - Parameter maxPixels: The longest side the stage needs.
    public func load(_ source: ImageSource, maxPixels: Int, completion: @escaping Completion) {
        let key = Key(source: source, maxPixels: maxPixels)
        if let image = cache[key] {
            touch(key)
            completion(.success(image))
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]
        let font = labelFont
        Task.detached(priority: .userInitiated) {
            let result = Self.decode(source, maxPixels: maxPixels, labelFont: font)
            await MainActor.run {
                if case .success(let image) = result { self.store(image, for: key) }
                let completions = self.waiting.removeValue(forKey: key) ?? []
                for completion in completions { completion(result) }
            }
        }
    }

    nonisolated private static func decode(_ source: ImageSource, maxPixels: Int, labelFont: CTFont) -> Result<CGImage, Failure> {
        switch source {
        case .label(let text):
            let width = maxPixels, height = Int((Double(maxPixels) * 9 / 16).rounded())
            guard let image = LabelPainter.image(text, width: width, height: height, font: labelFont) else {
                return .failure(Failure(reason: .undecodable))
            }
            return .success(image)
        case .file(let url):
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return .failure(Failure(reason: .missing))
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                return .failure(Failure(reason: .undecodable))
            }
            return .success(image)
        }
    }
}

/// Draws a cue's label on black, for an image cue with no picture: centred,
/// in the stage's type, big enough to read from the house but well short of
/// a title, and narrowed for a long label so it never runs off the edge.
enum LabelPainter {
    /// The label's height as a share of the picture's.
    static let size = 0.06

    static func image(_ text: String, width: Int, height: Int, font: CTFont) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return ctx.makeImage() }
        func line(at size: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateCopyWithAttributes(font, size, nil, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.bone.cgColor,
                NSAttributedString.Key(kCTKernAttributeName as String): size * 0.08,
            ]))
        }
        var size = CGFloat(height) * Self.size
        var drawn = line(at: size)
        let widest = CGFloat(width) * 0.9
        let measured = CGFloat(CTLineGetTypographicBounds(drawn, nil, nil, nil))
        if measured > widest {
            size *= widest / measured
            drawn = line(at: size)
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(drawn, &ascent, &descent, nil))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: (CGFloat(height) - ascent + descent) / 2)
        CTLineDraw(drawn, ctx)
        return ctx.makeImage()
    }
}
