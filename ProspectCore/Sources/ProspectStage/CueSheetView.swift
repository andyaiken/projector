import AppKit
import ProspectCore

/// The cue sheet on paper. It is read on a music stand under a single lamp,
/// so: portrait A4 or US Letter, black on white, at least 11 point text, the
/// cue number larger and bolder than anything else in its row, generous row
/// spacing with room for pencil, and rows that never split across a page.
/// Every page repeats the show title, the date printed and page n of m.
///
/// Laid out as pages stacked top to bottom, each one paper-sized, so the
/// print system can take them one at a time.
@MainActor
public final class CueSheetView: NSView {
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .bold)
    static let bodyFont = NSFont.systemFont(ofSize: 11)
    static let leadFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let stampFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .bold)
    static let metaFont = NSFont.systemFont(ofSize: 10)
    static let headingFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    public static let a4 = NSSize(width: 595.28, height: 841.89)
    public static let letter = NSSize(width: 612, height: 792)

    /// About 15 mm: inside any printer's unprintable edge.
    static let margin: CGFloat = 42
    static let padding: CGFloat = 10

    public var sheet: CueSheet {
        didSet { paginate() }
    }

    public let printed: Date
    public private(set) var paper: NSSize

    /// Builds the sheet again when the print panel switches layout.
    public var makeSheet: ((CueSheet.Layout) -> CueSheet)?
    public weak var options: CueSheetOptions?

    struct Placed {
        let row: CueSheet.Row
        /// From the top of its page.
        let y: CGFloat
        let height: CGFloat
    }

    private(set) var pages: [[Placed]] = [[]]

    public init(sheet: CueSheet, paper: NSSize = CueSheetView.a4, printed: Date = Date()) {
        self.sheet = sheet
        self.paper = paper
        self.printed = printed
        super.init(frame: .zero)
        paginate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var isFlipped: Bool { true }

    public var pageCount: Int { pages.count }

    public func lay(out paper: NSSize) {
        self.paper = paper
        paginate()
    }

    // MARK: Pages

    /// The operator's sheet adds a line explaining the starred values.
    private var printsKey: Bool { sheet.layout == .operatorSettings && sheet.hasOverrides }

    var headerHeight: CGFloat { Self.margin + 60 + (printsKey ? 14 : 0) }

    private func paginate() {
        pages = [[]]
        var y = headerHeight
        let bottom = paper.height - Self.margin
        for row in sheet.rows {
            let h = height(of: row)
            // A row that doesn't fit starts the next page whole.
            if y + h > bottom, !pages[pages.count - 1].isEmpty {
                pages.append([])
                y = headerHeight
            }
            pages[pages.count - 1].append(Placed(row: row, y: y, height: h))
            y += h
        }
        setFrameSize(NSSize(width: paper.width, height: paper.height * CGFloat(pages.count)))
        needsDisplay = true
    }

    struct Column {
        let x: CGFloat
        let width: CGFloat
    }

    /// Wide enough for the longest type name, and the AUTO stamp beneath it,
    /// on one line.
    private static let typeWidth = max(70, Cue.Kind.allCases
        .map { ceil(text($0.heading, bodyFont).size().width) + 2 }.max() ?? 0)

    /// Cue, type, content, and either the cue point or the settings.
    var columns: [Column] {
        let gap: CGFloat = 14
        let left = Self.margin, width = paper.width - 2 * Self.margin
        let cue: CGFloat = 52, type = Self.typeWidth
        let rest = width - cue - type - 3 * gap
        let content = (rest * (sheet.layout == .dsm ? 0.42 : 0.44)).rounded()
        return [
            Column(x: left, width: cue),
            Column(x: left + cue + gap, width: type),
            Column(x: left + cue + type + 2 * gap, width: content),
            Column(x: left + cue + type + content + 3 * gap, width: rest - content),
        ]
    }

    func height(of row: CueSheet.Row) -> CGFloat {
        let c = columns
        let heights = [
            Self.measure(Self.number(row.number), width: c[0].width),
            typeHeight(row),
            Self.measure(content(row), width: c[2].width),
            Self.measure(lastColumn(row), width: c[3].width),
        ]
        // Room to write: the DSM annotates in pencil.
        let minimum: CGFloat = sheet.layout == .dsm ? 60 : 44
        return max(minimum, (heights.max() ?? 0) + 2 * Self.padding).rounded(.up)
    }

    private func typeHeight(_ row: CueSheet.Row) -> CGFloat {
        let line = Self.measure(Self.text(row.type, Self.bodyFont), width: columns[1].width)
        return row.auto ? line + 6 + stampSize.height : line
    }

    private var stampSize: NSSize {
        let size = Self.text("AUTO", Self.stampFont).size()
        return NSSize(width: ceil(size.width) + 10, height: ceil(size.height) + 4)
    }

    // MARK: Text

    private static func text(_ string: String, _ font: NSFont, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
    }

    private static func number(_ number: String) -> NSAttributedString {
        text(number, numberFont, alignment: .right)
    }

    private static func measure(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        guard string.length > 0 else { return 0 }
        return ceil(string.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private func content(_ row: CueSheet.Row) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, line) in row.content.enumerated() {
            if i > 0 { out.append(Self.text("\n", Self.bodyFont)) }
            out.append(Self.text(line, i == 0 ? Self.leadFont : Self.bodyFont))
        }
        return out
    }

    /// The cue point, or nothing at all where none is set; or the settings,
    /// with values set for this cue in bold and starred.
    private func lastColumn(_ row: CueSheet.Row) -> NSAttributedString {
        guard sheet.layout == .operatorSettings else { return Self.text(row.cuePoint, Self.bodyFont) }
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 74)]
        style.lineSpacing = 2
        let out = NSMutableAttributedString()
        for (i, setting) in row.settings.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: setting.name + "\t", attributes: [.font: Self.bodyFont, .foregroundColor: NSColor.black]))
            out.append(NSAttributedString(string: setting.value + (setting.overridden ? " *" : ""), attributes: [
                .font: setting.overridden ? Self.leadFont : Self.bodyFont, .foregroundColor: NSColor.black,
            ]))
        }
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: Drawing

    override public func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        for (i, page) in pages.enumerated() {
            let top = CGFloat(i) * paper.height
            guard dirtyRect.intersects(NSRect(x: 0, y: top, width: paper.width, height: paper.height)) else { continue }
            drawHeader(page: i + 1, top: top)
            for placed in page { draw(placed.row, top: top + placed.y, height: placed.height) }
            if sheet.rows.isEmpty {
                Self.text("No cues yet.", Self.bodyFont).draw(at: NSPoint(x: Self.margin, y: top + headerHeight + Self.padding))
            }
        }
    }

    private func drawHeader(page: Int, top: CGFloat) {
        let left = Self.margin, right = paper.width - Self.margin, width = right - left
        var y = top + Self.margin
        Self.text(sheet.title.isEmpty ? "Untitled" : sheet.title, Self.titleFont)
            .draw(with: NSRect(x: left, y: y, width: width * 0.7, height: 22), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        Self.text("Page \(page) of \(pages.count)", Self.bodyFont, alignment: .right)
            .draw(with: NSRect(x: left + width * 0.7, y: y + 3, width: width * 0.3, height: 16), options: .usesLineFragmentOrigin)
        y += 22

        let date = DateFormatter.localizedString(from: printed, dateStyle: .long, timeStyle: .short)
        Self.text("Projection cue sheet \u{00B7} \(sheet.layout.name) \u{00B7} printed \(date)", Self.metaFont)
            .draw(with: NSRect(x: left, y: y, width: width, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if printsKey {
            y += 14
            Self.text("Values marked * are set for that cue; the rest are the show\u{2019}s defaults.", Self.metaFont)
                .draw(with: NSRect(x: left, y: y, width: width, height: 14), options: .usesLineFragmentOrigin)
        }
        y += 24

        let c = columns
        let headings = ["CUE", "TYPE", "CONTENT", sheet.layout == .dsm ? "CUE POINT" : "SETTINGS"]
        for (i, heading) in headings.enumerated() {
            let attributed = NSMutableAttributedString(attributedString: Self.text(heading, Self.headingFont, alignment: i == 0 ? .right : .left))
            attributed.addAttribute(.kern, value: 0.8, range: NSRange(location: 0, length: attributed.length))
            attributed.draw(with: NSRect(x: c[i].x, y: y, width: c[i].width, height: 12), options: .usesLineFragmentOrigin)
        }
        NSColor.black.setFill()
        NSRect(x: left, y: top + headerHeight - 4, width: width, height: 1).fill()
    }

    private func draw(_ row: CueSheet.Row, top: CGFloat, height: CGFloat) {
        let c = columns, y = top + Self.padding
        // The number sits on the same baseline as the first line beside it.
        let lift = Self.numberFont.ascender - Self.bodyFont.ascender
        Self.number(row.number).draw(with: NSRect(x: c[0].x, y: y - lift, width: c[0].width, height: height),
                                     options: .usesLineFragmentOrigin)
        let type = Self.text(row.type, Self.bodyFont)
        type.draw(with: NSRect(x: c[1].x, y: y, width: c[1].width, height: height), options: .usesLineFragmentOrigin)
        if row.auto {
            // Boxed, so a cue nobody presses GO for can't be missed.
            let stamp = NSRect(origin: NSPoint(x: c[1].x, y: y + Self.measure(type, width: c[1].width) + 6), size: stampSize)
            NSColor.black.setStroke()
            let box = NSBezierPath(rect: stamp.insetBy(dx: 0.5, dy: 0.5))
            box.lineWidth = 1
            box.stroke()
            Self.text("AUTO", Self.stampFont).draw(at: NSPoint(x: stamp.minX + 5, y: stamp.minY + 2))
        }
        content(row).draw(with: NSRect(x: c[2].x, y: y, width: c[2].width, height: height), options: .usesLineFragmentOrigin)
        lastColumn(row).draw(with: NSRect(x: c[3].x, y: y, width: c[3].width, height: height), options: .usesLineFragmentOrigin)

        NSColor(white: 0, alpha: 0.35).setFill()
        NSRect(x: Self.margin, y: top + height - 0.5, width: paper.width - 2 * Self.margin, height: 0.5).fill()
    }

    // MARK: Printing

    /// The print system asks for pages after the panel has set the paper
    /// and the layout, so the sheet is laid out again for them here.
    override public func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let options, options.layout != sheet.layout, let makeSheet { sheet = makeSheet(options.layout) }
        if let info = NSPrintOperation.current?.printInfo, info.paperSize != paper { lay(out: info.paperSize) }
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override public func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * paper.height, width: paper.width, height: paper.height)
    }
}

/// The print panel's choice of layout: the DSM's, with cue points, or the
/// operator's, with settings.
@MainActor
public final class CueSheetOptions: NSViewController, NSPrintPanelAccessorizing {
    @objc public dynamic var layoutIndex: Int

    public var layout: CueSheet.Layout { CueSheet.Layout.allCases[layoutIndex] }

    public init(layout: CueSheet.Layout) {
        layoutIndex = CueSheet.Layout.allCases.firstIndex(of: layout) ?? 0
        super.init(nibName: nil, bundle: nil)
        title = "Cue Sheet"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func loadView() {
        let label = NSTextField(labelWithString: "Layout:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: CueSheet.Layout.allCases.map(\.name))
        popup.selectItem(at: layoutIndex)
        popup.target = self
        popup.action = #selector(chosen(_:))
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        view = row
    }

    @objc private func chosen(_ sender: NSPopUpButton) {
        layoutIndex = sender.indexOfSelectedItem
    }

    public func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Cue sheet layout", .itemDescription: layout.name]]
    }

    public func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["layoutIndex"]
    }
}

@MainActor
public enum CueSheetPrinting {
    /// A print operation for a show's cue sheet. Margins are the sheet's
    /// own, so the print system's are set to nothing.
    public static func operation(for show: Show, title: String, layout: CueSheet.Layout,
                                 printInfo base: NSPrintInfo = .shared, printed: Date = Date()) -> NSPrintOperation {
        let info = base.copy() as! NSPrintInfo
        info.orientation = .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let view = CueSheetView(sheet: CueSheet(show: show, title: title, layout: layout), paper: info.paperSize, printed: printed)
        view.makeSheet = { CueSheet(show: show, title: title, layout: $0) }
        let options = CueSheetOptions(layout: layout)
        view.options = options

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = "\(title) cue sheet"
        operation.printPanel.addAccessoryController(options)
        operation.printPanel.options.formUnion([.showsPaperSize, .showsPreview, .showsCopies, .showsPageRange])
        return operation
    }

    /// Writes the cue sheet straight to a PDF, with no panels.
    public static func exportPDF(for show: Show, title: String, layout: CueSheet.Layout, paper: NSSize,
                                 to url: URL, printed: Date = Date()) -> Bool {
        let info = NSPrintInfo()
        info.paperSize = paper
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = operation(for: show, title: title, layout: layout, printInfo: info, printed: printed)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }
}
