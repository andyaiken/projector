import Foundation

/// The `.prospect` package: one show that travels as a single object.
///
///     DaVinciCode.prospect/
///       show.json     the sheet, settings and display choice
///       media/        every image and clip, copied in on import
///       version       the format version, as a number
///
/// Works on the file wrapper the document read, so a save replaces show.json
/// and the version and leaves the media wrappers alone. Saved over the
/// original, unchanged media are linked rather than rewritten, which keeps
/// autosave cheap however large the clips are.
public enum ShowPackage {
    public static let showFile = "show.json"
    public static let mediaFolder = "media"
    public static let versionFile = "version"

    public enum ReadError: Error, Equatable {
        /// Not a folder with a show in it.
        case notAPackage
        /// show.json is there but can't be read as a show.
        case damaged(String)
        /// Written by a later version of the app.
        case newerVersion(Int)
    }

    // MARK: Reading and writing

    public static func read(_ package: FileWrapper) throws -> Show {
        guard package.isDirectory, let children = package.fileWrappers,
              let showWrapper = children[showFile], let data = showWrapper.regularFileContents else {
            throw ReadError.notAPackage
        }
        if let text = children[versionFile]?.regularFileContents.map({ String(decoding: $0, as: UTF8.self) }),
           let version = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), version > Show.formatVersion {
            throw ReadError.newerVersion(version)
        }
        do {
            return try Show(jsonData: data)
        } catch ShowFormatError.newerVersion(let version) {
            throw ReadError.newerVersion(version)
        } catch {
            throw ReadError.damaged(String(describing: error))
        }
    }

    /// The package for `show`: `existing` with show.json and the version
    /// replaced and its media untouched, or a new package.
    public static func updated(_ existing: FileWrapper?, with show: Show) throws -> FileWrapper {
        let package = existing ?? FileWrapper(directoryWithFileWrappers: [:])
        replaceFile(showFile, in: package, with: try show.jsonData())
        replaceFile(versionFile, in: package, with: Data("\(Show.formatVersion)\n".utf8))
        _ = media(of: package)
        return package
    }

    private static func replaceFile(_ name: String, in package: FileWrapper, with data: Data) {
        if let old = package.fileWrappers?[name] { package.removeFileWrapper(old) }
        package.addRegularFile(withContents: data, preferredFilename: name)
    }

    /// The media folder, made if it isn't there.
    private static func media(of package: FileWrapper) -> FileWrapper {
        if let media = package.fileWrappers?[mediaFolder], media.isDirectory { return media }
        let media = FileWrapper(directoryWithFileWrappers: [:])
        media.preferredFilename = mediaFolder
        package.addFileWrapper(media)
        return media
    }

    // MARK: Media

    /// Copies the file at `url` into the media folder, as it stands: no
    /// re-encoding, so what the edit exported is what plays. Keeps the file's
    /// name unless that is taken. Returns its path in the package, which is
    /// what a cue stores.
    public static func importMedia(from url: URL, into package: FileWrapper) throws -> String {
        let folder = media(of: package)
        let name = uniqueName(url.lastPathComponent, taken: Set(folder.fileWrappers?.keys.map { $0 } ?? []))
        let file = try FileWrapper(url: url, options: [])
        file.preferredFilename = name
        file.filename = name
        let key = folder.addFileWrapper(file)
        return mediaFolder + "/" + key
    }

    /// `louvre.jpg`, then `louvre 2.jpg`, `louvre 3.jpg`... Compared without
    /// regard to case, as the Mac's disks compare names.
    public static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let lower = Set(taken.map { $0.lowercased() })
        guard lower.contains(name.lowercased()) else { return name }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !lower.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// Every file in the media folder, as paths in the package.
    public static func mediaPaths(in package: FileWrapper) -> [String] {
        guard let folder = package.fileWrappers?[mediaFolder], let files = folder.fileWrappers else { return [] }
        return files.keys.sorted().map { mediaFolder + "/" + $0 }
    }

    /// Media no cue refers to. Removing a picture from a cue leaves its file
    /// in the package, where an undo expects to find it; this finds what can
    /// go for Remove Unused Media.
    public static func unusedMedia(in package: FileWrapper, show: Show) -> [String] {
        let used = Set(show.cues.compactMap(\.mediaPath))
        return mediaPaths(in: package).filter { !used.contains($0) }
    }

    public static func removeMedia(_ paths: [String], from package: FileWrapper) {
        guard let folder = package.fileWrappers?[mediaFolder] else { return }
        for path in paths {
            let name = String(path.dropFirst(mediaFolder.count + 1))
            if let file = folder.fileWrappers?[name] { folder.removeFileWrapper(file) }
        }
    }
}

extension Cue {
    /// The picture or clip this cue plays, as a path in the package.
    public var mediaPath: String? {
        switch content {
        case .image(let c): c.src.isEmpty ? nil : c.src
        case .video(let c): c.src.isEmpty ? nil : c.src
        case .title, .blank: nil
        }
    }
}

/// The one piece of state worth recovering after a crash: which show, and
/// which cue was last fired. Written outside the document whenever a cue
/// fires, and removed on a clean quit, so finding one at launch means the
/// app went down mid-show.
public struct CrashRecord: Codable, Equatable, Sendable {
    public var show: URL
    public var cue: UUID
    public var cueNumber: String
    public var firedAt: Date

    public init(show: URL, cue: UUID, cueNumber: String, firedAt: Date) {
        self.show = show
        self.cue = cue
        self.cueNumber = cueNumber
        self.firedAt = firedAt
    }

    public static func read(from url: URL) -> CrashRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CrashRecord.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
