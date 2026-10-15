import AppKit
import PDFKit
import ProspectCore
import Testing
@testable import ProspectStage

/// The printed sheet, checked by printing it to PDF and reading it back.
@Suite("Printed cue sheet", .serialized)
@MainActor
struct CueSheetViewTests {
    let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CueSheet-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Forty cues, in the shape of the real sheet: titles, images, blanks,
    /// a video the picture before it continues into, cue points on some and
    /// not others.
    let show: Show = {
        var cues: [Cue] = []
        for n in 1...40 {
            switch n % 4 {
            case 1: cues.append(Cue(number: "\(n)", line: n % 8 == 1 ? "LANGDON: \u{201C}\u{2026}the rose line.\u{201D} Langdon crosses down left and kneels by the brass strip." : "",
                                    content: .title(TitleContent(text: "THE LOUVRE \(n)", sub: "PARIS", key: "VITRUVIAN", overrides: n == 5 ? TitleOverrides(clockMs: 30) : .init()))))
            case 2: cues.append(Cue(number: "\(n)", line: "Lights fade on the gallery", continueMode: n == 10 ? .whenFinished : .whenCued,
                                    content: .image(ImageContent(text: "GRAND GALLERY \(n)"))))
            case 3: cues.append(Cue(number: "\(n)", content: .video(VideoContent(text: "CRYPTEX \(n)", src: "media/cryptex.mov", atEnd: .black))))
            default: cues.append(Cue(number: "\(n)", content: .blank(BlankContent())))
            }
        }
        return Show(title: "The Da Vinci Code", cues: cues)
    }()

    func pdf(_ layout: CueSheet.Layout, paper: NSSize = CueSheetView.a4, show: Show? = nil) throws -> PDFDocument {
        let url = folder.appendingPathComponent("\(layout.rawValue)-\(Int(paper.height)).pdf")
        #expect(CueSheetPrinting.exportPDF(for: show ?? self.show, title: "The Da Vinci Code", layout: layout, paper: paper, to: url))
        return try #require(PDFDocument(url: url))
    }

    func text(of document: PDFDocument, page: Int) -> String {
        document.page(at: page)?.string ?? ""
    }

    @Test("Every page repeats the title and says which page of how many")
    func headers() throws {
        let document = try pdf(.dsm)
        #expect(document.pageCount > 1, "forty cues don't fit one page")
        for i in 0..<document.pageCount {
            let page = text(of: document, page: i)
            #expect(page.contains("The Da Vinci Code"))
            #expect(page.contains("Page \(i + 1) of \(document.pageCount)"))
            #expect(page.contains("CUE POINT"))
        }
    }

    @Test("Rows never split across pages, and every cue is printed once, in order")
    func rowsStayWhole() throws {
        let view = CueSheetView(sheet: CueSheet(show: show, title: "The Da Vinci Code", layout: .dsm))
        for page in view.pages {
            for placed in page {
                #expect(placed.y >= view.headerHeight)
                #expect(placed.y + placed.height <= view.paper.height - CueSheetView.margin, "row \(placed.row.number) runs off its page")
            }
        }
        #expect(view.pages.flatMap { $0 }.map(\.row.number) == (1...40).map(String.init))
        #expect(try pdf(.dsm).pageCount == view.pageCount)
    }

    @Test("Portrait A4 and US Letter")
    func paperSizes() throws {
        let a4 = try #require(try pdf(.dsm, paper: CueSheetView.a4).page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(a4.width - 595.28) < 1 && abs(a4.height - 841.89) < 1)
        let letter = try #require(try pdf(.dsm, paper: CueSheetView.letter).page(at: 0)?.bounds(for: .mediaBox))
        #expect(letter.size == CGSize(width: 612, height: 792))
    }

    @Test("A cue fired by the one before it is marked AUTO, and an empty cue point prints nothing, not a dash")
    func dsmContent() throws {
        let document = try pdf(.dsm)
        let all = (0..<document.pageCount).map { text(of: document, page: $0) }.joined(separator: "\n")
        #expect(all.contains("AUTO"))
        #expect(all.components(separatedBy: "AUTO").count == 2, "one cue fired by the one before, one marker")
        #expect(all.contains("Lights fade on the gallery"))
        #expect(!all.contains("\u{2014}") && !all.contains(" - "), "no dashes standing in for missing cue points")
    }

    @Test("The operator's sheet has settings and no cue points")
    func operatorContent() throws {
        let document = try pdf(.operatorSettings)
        let all = (0..<document.pageCount).map { text(of: document, page: $0) }.joined(separator: "\n")
        #expect(all.contains("SETTINGS"))
        #expect(all.contains("Hold") && all.contains("cut to black") && all.contains("cryptex.mov"))
        #expect(all.contains("30 ms *"), "the one override is marked")
        #expect(all.contains("are set for that cue"), "and the key to the marking is printed")
        #expect(!all.contains("Lights fade on the gallery"))
    }

    @Test("Type is at least 11 point, and the cue number is the largest and boldest in its row")
    func type() {
        let body = [CueSheetView.bodyFont, CueSheetView.leadFont, CueSheetView.stampFont]
        #expect(body.allSatisfy { $0.pointSize >= 11 })
        #expect(body.allSatisfy { CueSheetView.numberFont.pointSize > $0.pointSize })
        #expect(NSFontManager.shared.weight(of: CueSheetView.numberFont) >= NSFontManager.shared.weight(of: CueSheetView.stampFont))
    }

    @Test("An empty sheet still prints a page")
    func emptySheet() throws {
        let document = try pdf(.dsm, show: Show(title: "New"))
        #expect(document.pageCount == 1)
        #expect(text(of: document, page: 0).contains("No cues yet"))
    }

    @Test("The pages, for looking at")
    func snapshot() {
        for layout in CueSheet.Layout.allCases {
            let view = CueSheetView(sheet: CueSheet(show: show, title: "The Da Vinci Code", layout: layout),
                                    printed: Date(timeIntervalSince1970: 1_792_051_200))
            let rect = view.rectForPage(1)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { continue }
            view.cacheDisplay(in: rect, to: rep)
            if let directory = ProcessInfo.processInfo.environment["PROSPECT_SNAPSHOTS"] {
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("cue-sheet-\(layout.rawValue).png"))
            }
        }
    }
}
