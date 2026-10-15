import AppKit
import ProspectCore
import QuartzCore
@testable import ProspectStage

/// A title cue, as the sheet holds it.
func titleCue(_ text: String, sub: String = "", key: String = "SANGREAL", overrides: TitleOverrides = .init()) -> Cue {
    Cue(number: "1", content: .title(TitleContent(text: text, sub: sub, key: key, overrides: overrides)))
}

/// A surface of a given size, with its inset placed.
@MainActor
func surface(width: CGFloat = 1920, height: CGFloat = 1080, role: SurfaceLayer.Role = .live, geometry: Geometry = .init()) -> SurfaceLayer {
    let s = SurfaceLayer(role: role)
    s.frame = CGRect(x: 0, y: 0, width: width, height: height)
    s.geometry = geometry
    s.contentsScale = 1
    return s
}

@MainActor
func tree(_ renderer: TitleRenderer, on surface: SurfaceLayer) -> TitleRenderer.Tree? {
    renderer.tree(for: surface)
}

/// The text a line of runs reads, in order.
func text(of runs: [TextRun]) -> String {
    runs.map(\.text).joined()
}

/// Renders a surface into an RGBA bitmap, as the projector would show it.
@MainActor
func render(_ surface: SurfaceLayer) -> Bitmap {
    func display(_ layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach(display)
    }
    display(surface)
    let w = Int(surface.bounds.width), h = Int(surface.bounds.height)
    let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    surface.render(in: context)
    return Bitmap(context: context, width: w, height: h)
}

struct Bitmap {
    let context: CGContext
    let width: Int
    let height: Int

    /// The pixel at a point measured from the top left.
    func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        // Bitmap contexts store the top row first.
        let i = (y * width + x) * 4
        return (data[i], data[i + 1], data[i + 2])
    }

    func isBlack(x: Int, y: Int) -> Bool {
        let p = pixel(x: x, y: y)
        return p.r == 0 && p.g == 0 && p.b == 0
    }

    /// Writes a PNG when PROSPECT_SNAPSHOTS names a directory, for looking at.
    func save(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["PROSPECT_SNAPSHOTS"],
              let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
