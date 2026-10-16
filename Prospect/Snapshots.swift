#if DEBUG
import AppKit
import ProspectCore
import ProspectStage
import QuartzCore

/// Debug builds only: renders the console offscreen to PNGs and quits, so its
/// layout can be looked at without driving the screen.
///
///     Prospect.app/Contents/MacOS/Prospect -ProspectSnapshot /some/folder
@MainActor
enum Snapshots {
    static func run(to directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var show = sheet()
        // A video cue with no clip after cue 1, to show the standby panel's
        // armed line when it stands by.
        show.cues.insert(Cue(number: "1.5", content: .video(VideoContent(text: "CRYPTEX", sub: "REVEAL", src: "media/cryptex.mov"))), at: 1)
        // Two transitions of their own: a snap into the first blank, and a
        // slower fade into the second picture.
        show.cues[3].transition = TransitionOverrides(style: .snap)
        show.cues[5].transition = TransitionOverrides(fadeMs: 1200)
        // And a timed continue, on the cue the editor shows.
        show.cues[4].continueMode = .after(ms: 5000)
        show.cues[7].continueMode = .whenFinished
        // The first picture goes in a golden spiral, so the frame caught
        // mid-reveal shows its shape.
        if case .image(var first) = show.cues[2].content {
            first.overrides.order = .spiral
            show.cues[2].content = .image(first)
        }
        show.cues[5].continueMode = .whenFinished(waitMs: 2000)
        let document = ShowDocument(show: show, warnings: [])
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        guard let controller = document.controller, let console = document.console else { exit(1) }
        console.window?.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 860), display: false)
        controller.enterShowMode()
        let start = CACurrentMediaTime()

        // Cue 1 fired and settled, the video standing by.
        controller.go()
        for i in 1...720 { controller.tick(at: start + Double(i) / 60) }
        save(console, "console-show", to: directory)
        // The wordmark partway through decrypting, as when the window opens,
        // then home again.
        console.holdWordmark(atFrame: 14)
        save(console, "console-wordmark", to: directory)
        console.holdWordmark(atFrame: 1000)

        // Past the video, which goes to black at once.
        controller.go()
        controller.tick(at: start + 13)

        // Cue 2, an image cue with no picture, so its label on black:
        // mid-flip, then settled. It
        // goes up once the video has faded out, and its picture decodes in the
        // background, so the run loop gets a moment.
        let fired = CACurrentMediaTime()
        controller.go()
        controller.tick(at: fired + 0.6)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        controller.tick(at: fired + 0.5 + 0.044 * 70)
        save(console, "console-image-turning", to: directory)
        controller.tick(at: fired + 30)
        save(console, "console-image", to: directory)

        // Edit mode: guides, a pulled-in projection area, and the editor on a
        // title cue, then on an image cue.
        controller.enterEditMode()
        controller.showsGuides = true
        controller.setGeometry(Geometry(width: 90, height: 86, across: 2, down: -3))
        controller.standBy(controller.show.cues[4].id)
        save(console, "console-edit", to: directory)
        controller.standBy(controller.show.cues[5].id)
        save(console, "console-edit-image", to: directory)

        // The settings tabs: the image cue with two values of its own, then
        // the show's defaults.
        let image = controller.show.cues[5].id
        controller.setOverride(.grid, to: .number(20), for: image)
        controller.setOverride(.order, to: .order(.spiral), for: image)
        controller.setOverride(.reveal, to: .reveal(.sharpen), for: image)
        console.showEditTab(1)
        save(console, "console-cue-settings", to: directory)
        console.showEditTab(2)
        save(console, "console-show-defaults", to: directory)
        // A decryption cue whose letters are on dials.
        let decryption = controller.show.cues[4].id
        controller.setOverride(.letters, to: .letters(.dials), for: decryption)
        controller.standBy(decryption)
        console.showEditTab(1)
        save(console, "console-cue-settings-decryption", to: directory)

        // A cue just added: every field empty, and flagged.
        console.showEditTab(0)
        controller.addCue(.title)
        save(console, "console-new-cue", to: directory)

        // An anagram cue in the editor.
        if let anagram = controller.addCue(.anagram) {
            controller.updateCue(anagram, "Change Phrase") { cue in
                cue.text = "O, Draconian devil! Oh, lame saint!"
                cue.sub = "Leonardo da Vinci! The Mona Lisa!"
            }
            save(console, "console-edit-anagram", to: directory)
        }

        // Prospect › Settings.
        let preferences = PreferencesWindowController()
        if let view = preferences.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
        }

        exit(0)
    }

    /// A short show to photograph: three places, each a decryption, its
    /// picture (none yet, so its label on black), and a blank.
    private static func sheet() -> Show {
        let places = [("THE LOUVRE", "PARIS", "VITRUVIAN"),
                      ("SAINT-SULPICE", "PARIS", "ROSELINE"),
                      ("CHATEAU VILLETTE", "VERSAILLES", "SANGREAL")]
        var cues: [Cue] = []
        for (place, city, key) in places {
            cues.append(Cue(number: "\(cues.count + 1)", content: .title(TitleContent(text: place, sub: city, key: key))))
            cues.append(Cue(number: "\(cues.count + 1)", content: .image(ImageContent(text: place))))
            cues.append(Cue(number: "\(cues.count + 1)", content: .blank(BlankContent())))
        }
        return Show(title: "The Da Vinci Code", cues: cues)
    }

    private static func save(_ console: ConsoleWindowController, _ name: String, to directory: String) {
        guard let view = console.window?.contentView else { return }
        console.refresh()
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        // Layer-hosting views aren't drawn by cacheDisplay, so the preview's
        // surface is rendered into its place.
        if let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
            let preview = console.preview
            let frame = preview.convert(preview.bounds, to: view)
            func display(_ layer: CALayer) {
                layer.displayIfNeeded()
                layer.sublayers?.forEach(display)
            }
            display(preview.surface)
            context.saveGState()
            // The view is flipped; Core Animation draws from the bottom.
            context.translateBy(x: frame.minX, y: view.bounds.height - frame.maxY)
            preview.surface.render(in: context)
            context.restoreGState()
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Debug builds only: drives a document through import, Save As, Save and
/// reopen, checking each step, and writes what it found to result.txt.
///
///     Prospect.app/Contents/MacOS/Prospect -ProspectDocumentCheck /some/folder
@MainActor
enum DocumentCheck {
    private static var lines: [String] = []
    private static var failed = false

    private static func check(_ ok: Bool, _ what: String) {
        lines.append((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failed = true }
    }

    private static func write(to folder: URL) {
        try? (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    private static func finish(in folder: URL) -> Never {
        // The scratch show shouldn't be what the app reopens next launch.
        NSDocumentController.shared.clearRecentDocuments(nil)
        write(to: folder)
        exit(failed ? 1 : 0)
    }

    /// The last check edits the open show and closes its console, as the
    /// operator would. That must save the edit and quit. Prospect exits if it
    /// passes and hangs if it doesn't, so whatever runs the check has to notice
    /// a hang, and look for the edit in the saved show.json.
    private static func finish(in folder: URL, closing document: ShowDocument?) {
        guard !failed, let document, let console = document.console?.window as? ConsoleWindow else { finish(in: folder) }
        document.enterEditMode()
        document.controller?.setTitle("Check, closed with this unsaved")
        // AppKit counts an edit as unsaved once the run loop goes idle after
        // it, so the console is closed a moment later, as in use.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            check(document.show.title == "Check, closed with this unsaved", "the title can be edited in edit mode")
            check(document.isDocumentEdited, "an edit marks the show as changed")
            guard !failed else { finish(in: folder) }
            NSDocumentController.shared.clearRecentDocuments(nil)
            lines.append("LAST  closing the console with an unsaved edit saves it and quits: Prospect exits now if this passes, and hangs if it doesn't")
            write(to: folder)
            console.performClose(nil)
            // Quitting can finish on a later turn of the run loop. If it
            // still hasn't after a while, it was refused.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                check(false, "closing the console didn't quit")
                write(to: folder)
                exit(1)
            }
        }
    }

    private static func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    static func run(in directory: String) {
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // A picture to import.
        let picture = folder.appendingPathComponent("gallery.png")
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.8, green: 0.6, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])?.write(to: picture)

        let document = ShowDocument(show: Show(title: "Check"), warnings: [])
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        guard let controller = document.controller else { finish(in: folder) }
        check(document.windowControllers.contains { $0 === document.console } && document.console?.document === document,
              "the console belongs to the show, so showing the show shows it")
        // Closing the console must go to Quit without asking the show whether
        // it can close first: quitting from inside that request deadlocks.
        if let window = document.console?.window as? ConsoleWindow {
            var quitAsked = false
            window.onPerformClose = { quitAsked = true }
            window.performClose(nil)
            check(quitAsked && document.windowControllers.contains { $0 === document.console },
                  "closing the console asks to quit, and leaves the show to Quit")
            window.onPerformClose = { NSApp.terminate(nil) }
        } else {
            check(false, "the console is a ConsoleWindow, whose close is Quit")
        }
        check(controller.mode == .edit, "a new show starts in edit mode")
        guard let titleID = controller.addCue(.title), let imageID = controller.addCue(.image) else {
            check(false, "cues can be added")
            finish(in: folder)
        }
        check(controller.show.cues.map(\.number) == ["1", "2"], "added cues are numbered 1 and 2")

        // A row dragged by its grip lands where it's dropped; dropped next to
        // itself, it doesn't move.
        let landings = [(0, 0), (0, 1), (0, 2), (0, 3), (2, 0), (2, 3), (3, 1)].map { CueListView.offset(moving: $0, toSlot: $1) }
        check(landings == [0, 0, 1, 2, -2, 0, -2], "dragging a cue moves it by \(landings)")

        // Tab runs down what the cue shows, then where it comes in the book,
        // skipping what this kind of cue doesn't have.
        if let console = document.console {
            func stops(for id: UUID) -> [String] {
                controller.standBy(id)
                console.refresh()
                console.window?.contentView?.layoutSubtreeIfNeeded()
                return console.editor.tabStops
            }
            let decryption = stops(for: titleID), image = stops(for: imageID)
            check(decryption == ["text", "sub", "key", "number", "line"], "Tab through a decryption cue: \(decryption.joined(separator: ", "))")
            check(image == ["text", "number", "line"], "Tab through an image cue, which has no caption: \(image.joined(separator: ", "))")
        }

        document.importMedia(from: picture, into: imageID)
        let src = controller.show[imageID]?.mediaPath ?? ""
        check(src == "media/gallery.png", "an imported picture gets a path in the package: \(src)")
        check(document.mediaURL(src) == picture, "before saving, it is read from where it came from")
        check(document.undoManager?.canUndo == true, "edits are undoable")

        let url = folder.appendingPathComponent("Check.prospect")
        try? FileManager.default.removeItem(at: url)
        document.save(to: url, ofType: ShowDocument.typeName, for: .saveAsOperation) { error in
            MainActor.assumeIsolated {
                check(error == nil, "Save As writes the package \(error.map { "\($0)" } ?? "")")
                let fm = FileManager.default
                check(fm.fileExists(atPath: url.appendingPathComponent("show.json").path)
                      && fm.fileExists(atPath: url.appendingPathComponent("version").path)
                      && fm.fileExists(atPath: url.appendingPathComponent(src).path), "show.json, version and the picture are in the package")
                check(document.mediaURL(src) == url.appendingPathComponent(src), "after saving, the picture is read from the package")
                let before = inode(url.appendingPathComponent(src))

                controller.updateCue(titleID, "Change Cue Point") { $0.line = "LANGDON: \u{201C}\u{2026}the rose line.\u{201D}" }
                document.save(to: url, ofType: ShowDocument.typeName, for: .saveOperation) { error in
                    MainActor.assumeIsolated {
                        check(error == nil, "Save writes again")
                        check(before != nil && inode(url.appendingPathComponent(src)) == before, "the second save left the picture where it was")
                        let json = (try? String(contentsOf: url.appendingPathComponent("show.json"), encoding: .utf8)) ?? ""
                        check(json.contains("the rose line"), "show.json has the edit")
                        document.close()

                        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { reopened, _, error in
                            MainActor.assumeIsolated {
                                let reopened = reopened as? ShowDocument
                                check(reopened != nil && error == nil, "the show reopens")
                                reopened?.makeWindowControllers()
                                check(reopened?.controller?.mode == .show, "a show opened from disk opens in show mode")
                                check(reopened?.show.cues.count == 2, "both cues came back")
                                let resolved = reopened?.mediaURL(src)?.standardizedFileURL.path
                                let expected = url.appendingPathComponent(src).standardizedFileURL.path
                                check(resolved == expected, "media resolve inside the package: \(resolved ?? "nil") / fileURL \(reopened?.fileURL?.absoluteString ?? "nil")")
                                check(reopened?.controller?.addCue(.blank) == nil, "and can't be edited until edit mode")

                                // The cue sheet, through what the menu items use.
                                let operation = try? reopened?.printOperation(withSettings: [:])
                                check(operation?.view is CueSheetView, "Print Cue Sheet prints the cue sheet")
                                let pdf = folder.appendingPathComponent("Check cue sheet.pdf")
                                if let reopened {
                                    check(CueSheetPrinting.exportPDF(for: reopened.show, title: reopened.sheetTitle, layout: .dsm,
                                                                     paper: CueSheetView.a4, to: pdf), "Export Cue Sheet as PDF writes a file")
                                }
                                let size = (try? FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? NSNumber)?.intValue ?? 0
                                check(size > 1000, "and it isn't empty (\(size) bytes)")
                                finish(in: folder, closing: reopened)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
