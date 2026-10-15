import Foundation
import Testing
@testable import ProspectCore

@Suite("The .prospect package")
struct ShowPackageTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShowPackage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func sample() -> Show {
        Show(title: "The Da Vinci Code", cues: [
            Cue(number: "1", content: .title(TitleContent(text: "THE LOUVRE", sub: "PARIS", key: "VITRUVIAN"))),
            Cue(number: "2", content: .image(ImageContent(text: "THE LOUVRE"))),
        ])
    }

    func file(_ name: String, _ text: String = "picture") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func inode(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber).uint64Value
    }

    @Test("A package holds show.json, a version and a media folder, and reads back")
    func roundTrip() throws {
        let url = folder.appendingPathComponent("Show.prospect")
        let show = sample()
        let package = try ShowPackage.updated(nil, with: show)
        try package.write(to: url, options: .atomic, originalContentsURL: nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        #expect(names == ["media", "show.json", "version"])
        #expect(try String(contentsOf: url.appendingPathComponent("version"), encoding: .utf8) == "\(Show.formatVersion)\n")
        #expect(try ShowPackage.read(FileWrapper(url: url, options: .immediate)) == show)
    }

    @Test("Imported media keep their names, de-duplicated, and travel with the show")
    func importing() throws {
        let package = try ShowPackage.updated(nil, with: sample())
        let first = try ShowPackage.importMedia(from: try file("louvre.jpg"), into: package)
        let second = try ShowPackage.importMedia(from: try file("Louvre.JPG"), into: package)
        #expect(first == "media/louvre.jpg")
        #expect(second == "media/Louvre 2.JPG")
        #expect(ShowPackage.mediaPaths(in: package) == ["media/Louvre 2.JPG", "media/louvre.jpg"])

        let url = folder.appendingPathComponent("Media.prospect")
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
        #expect(try String(contentsOf: url.appendingPathComponent(first), encoding: .utf8) == "picture")
    }

    @Test("Saving again replaces show.json and leaves media where they were")
    func savingLeavesMediaAlone() throws {
        let url = folder.appendingPathComponent("Cheap.prospect")
        var show = sample()
        let package = try ShowPackage.updated(nil, with: show)
        let path = try ShowPackage.importMedia(from: try file("clip.mov", String(repeating: "x", count: 100_000)), into: package)
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
        let before = try inode(url.appendingPathComponent(path))

        // As the document does: work on the wrapper read from disk, then save
        // over the original.
        let reread = try FileWrapper(url: url, options: [])
        show.cues[0].line = "LANGDON: \u{201C}\u{2026}the rose line.\u{201D}"
        let updated = try ShowPackage.updated(reread, with: show)
        let saved = folder.appendingPathComponent("Cheap-saved.prospect")
        try updated.write(to: saved, options: .atomic, originalContentsURL: url)

        #expect(try inode(saved.appendingPathComponent(path)) == before, "the clip was linked, not copied")
        #expect(try ShowPackage.read(FileWrapper(url: saved, options: .immediate)) == show)
    }

    @Test("Unused media are found, and only they are removed")
    func unusedMedia() throws {
        var show = sample()
        let package = try ShowPackage.updated(nil, with: show)
        let used = try ShowPackage.importMedia(from: try file("used.jpg"), into: package)
        let spare = try ShowPackage.importMedia(from: try file("spare.jpg"), into: package)
        guard case .image(var image) = show.cues[1].content else { return }
        image.src = used
        show.cues[1].content = .image(image)
        #expect(ShowPackage.unusedMedia(in: package, show: show) == [spare])
        ShowPackage.removeMedia([spare], from: package)
        #expect(ShowPackage.mediaPaths(in: package) == [used])
    }

    @Test("A damaged or foreign package is refused, not repaired")
    func refusals() throws {
        let damaged = FileWrapper(directoryWithFileWrappers: [
            "show.json": FileWrapper(regularFileWithContents: Data("{ not json".utf8)),
        ])
        do {
            _ = try ShowPackage.read(damaged)
            Issue.record("a damaged show.json should be refused")
        } catch ShowPackage.ReadError.damaged {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(throws: ShowPackage.ReadError.notAPackage) {
            try ShowPackage.read(FileWrapper(directoryWithFileWrappers: [:]))
        }
        let newer = FileWrapper(directoryWithFileWrappers: [
            "show.json": FileWrapper(regularFileWithContents: try sample().jsonData()),
            "version": FileWrapper(regularFileWithContents: Data("9\n".utf8)),
        ])
        #expect(throws: ShowPackage.ReadError.newerVersion(9)) { try ShowPackage.read(newer) }
    }

    @Test("Names are de-duplicated without regard to case")
    func uniqueNames() {
        #expect(ShowPackage.uniqueName("a.jpg", taken: []) == "a.jpg")
        #expect(ShowPackage.uniqueName("a.jpg", taken: ["A.JPG"]) == "a 2.jpg")
        #expect(ShowPackage.uniqueName("a.jpg", taken: ["a.jpg", "a 2.jpg"]) == "a 3.jpg")
        #expect(ShowPackage.uniqueName("README", taken: ["readme"]) == "README 2")
    }

    @Test("The crash record round-trips")
    func crashRecord() throws {
        let url = folder.appendingPathComponent("Support/LastCue.json")
        let record = CrashRecord(show: URL(fileURLWithPath: "/Shows/DaVinci.prospect"), cue: UUID(), cueNumber: "9.5",
                                 firedAt: Date(timeIntervalSince1970: 1_792_000_000))
        try record.write(to: url)
        #expect(CrashRecord.read(from: url) == record)
        #expect(CrashRecord.read(from: folder.appendingPathComponent("none.json")) == nil)
    }
}
