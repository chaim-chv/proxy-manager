import AppKit
import SwiftUI

struct FeedRow: Identifiable, Equatable {
    let event: RequestEvent
    let isLive: Bool
    var id: UUID { event.id }
}

/// The dashboard request feed, hosted as a view-based `NSTableView`.
///
/// Why AppKit instead of SwiftUI `Table`? SwiftUI's `Table` has no API to
/// persist user-adjusted column widths (`.width` is static; there is no resize
/// callback or binding). `NSTableView` ships the macOS-native mechanism for
/// exactly this: `autosaveName` + `autosaveTableColumns` write each column's
/// width to the app defaults the moment the user drags a divider and restore
/// them on the next launch. The cells mirror the previous SwiftUI look
/// (caption text, monospaced digits, live dot, route chip, inset style).
struct FeedTable: NSViewRepresentable {
    static let autosaveName = "ProxyManagerDashboardFeed"

    let rows: [FeedRow]
    @Binding var selectedID: UUID?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)

        FeedTable.addColumn(table, "dot", title: "", width: 18, min: 18, max: 18, resizable: false)
        FeedTable.addColumn(table, "time", title: "Time", width: 64, min: 48, max: 200, resizable: true)
        FeedTable.addColumn(table, "route", title: "Route", width: 74, min: 60, max: 200, resizable: true)
        FeedTable.addColumn(table, "method", title: "Method", width: 62, min: 50, max: 200, resizable: true)
        FeedTable.addColumn(table, "host", title: "Host", width: 300, min: 120, max: 4000, resizable: true)
        FeedTable.addColumn(table, "status", title: "Status", width: 48, min: 40, max: 200, resizable: true)
        FeedTable.addColumn(table, "bytes", title: "Bytes", width: 76, min: 60, max: 300, resizable: true)
        FeedTable.addColumn(table, "duration", title: "Duration", width: 66, min: 52, max: 300, resizable: true)
        // The last column absorbs leftover width when the window is resized
        // (NSTableView's built-in lastColumnOnlyAutoresizingStyle).
        FeedTable.addColumn(table, "error", title: "Error", width: 260, min: 100, max: 4000, resizable: true)

        let coordinator = context.coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.autosaveName = FeedTable.autosaveName
        table.autosaveTableColumns = true

        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSelect = { selectedID = $0 }
        context.coordinator.update(rows: rows, selectedID: selectedID)
    }

    private static func addColumn(_ table: NSTableView, _ id: String, title: String,
                                  width: CGFloat, min: CGFloat, max: CGFloat,
                                  resizable: Bool) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        column.maxWidth = max
        column.resizingMask = resizable ? .userResizingMask : []
        table.addTableColumn(column)
    }

    // MARK: - Coordinator (data source + delegate)

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate var table: NSTableView?
        fileprivate var onSelect: ((UUID?) -> Void)?
        private var rows: [FeedRow] = []
        private var lastRows: [FeedRow] = []
        private var lastIDs: [UUID] = []
        private var tableSelectionID: UUID?

        func update(rows newRows: [FeedRow], selectedID: UUID?) {
            guard let table = table else { return }
            rows = newRows

            // The owner cleared the selection (inspector dismissed): deselect.
            if selectedID == nil, tableSelectionID != nil {
                tableSelectionID = nil
                table.deselectAll(nil)
            }

            // Identity/order changed (new connection, finish, or filter) vs.
            // just live values ticking — this decides full vs. partial reload.
            let newIDs = newRows.map(\.id)
            let identityChanged = newIDs != lastIDs
            let contentChanged = newRows != lastRows
            lastRows = newRows
            lastIDs = newIDs

            guard contentChanged else { return }

            if identityChanged {
                table.reloadData()
                // reloadData() drops the selection; restore the user's pick.
                if let id = tableSelectionID, let idx = newRows.firstIndex(where: { $0.id == id }) {
                    table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                }
            } else if !newRows.isEmpty {
                // Same rows, same order (only bytes/duration ticked): refresh
                // only the on-screen rows.
                let range = table.rows(in: table.visibleRect)
                guard range.length > 0 else { return }
                let visible = IndexSet(integersIn: range.location..<(range.location + range.length))
                let columns = IndexSet(integersIn: 0..<table.numberOfColumns)
                table.reloadData(forRowIndexes: visible, columnIndexes: columns)
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        // MARK: NSTableViewDelegate

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = table else { return }
            let row = table.selectedRow
            let id = (row >= 0 && row < rows.count) ? rows[row].event.id : nil
            tableSelectionID = id
            onSelect?(id)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count, let tableColumn = tableColumn else { return nil }
            let feed = rows[row]
            let event = feed.event
            let reuseID = NSUserInterfaceItemIdentifier("Feed.\(tableColumn.identifier.rawValue)")

            switch tableColumn.identifier.rawValue {
            case "dot":
                return dot(reuseID, tableView: tableView, isLive: feed.isLive)
            case "time":
                return label(reuseID, tableView: tableView, text: Format.time(event.ts),
                             font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             color: .secondaryLabelColor, align: .left)
            case "route":
                return badge(reuseID, tableView: tableView, route: event.route)
            case "method":
                return label(reuseID, tableView: tableView, text: event.method,
                             font: .systemFont(ofSize: 11, weight: .regular),
                             color: .labelColor, align: .left)
            case "host":
                return host(reuseID, tableView: tableView, host: event.host, port: event.port)
            case "status":
                let text: String
                let color: NSColor
                if event.status > 0 {
                    text = "\(event.status)"
                    color = event.status >= 400 ? .systemRed : .secondaryLabelColor
                } else if feed.isLive {
                    text = "…"
                    color = .tertiaryLabelColor
                } else {
                    text = ""
                    color = .clear
                }
                return label(reuseID, tableView: tableView, text: text,
                             font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             color: color, align: .left)
            case "bytes":
                return label(reuseID, tableView: tableView, text: Format.bytes(event.bytesIn + event.bytesOut),
                             font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             color: .secondaryLabelColor, align: .right)
            case "duration":
                return label(reuseID, tableView: tableView, text: Format.duration(event.durationMs),
                             font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             color: feed.isLive ? .systemOrange : .secondaryLabelColor, align: .right)
            case "error":
                let err = event.error ?? ""
                return label(reuseID, tableView: tableView, text: err,
                             font: .systemFont(ofSize: 11, weight: .regular),
                             color: .systemRed, align: .left, truncation: .byTruncatingMiddle)
            default:
                return nil
            }
        }

        private func label(_ id: NSUserInterfaceItemIdentifier, tableView: NSTableView,
                           text: String, font: NSFont, color: NSColor,
                           align: NSTextAlignment, truncation: NSLineBreakMode = .byClipping) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FeedLabelCell) ?? FeedLabelCell()
            cell.identifier = id
            cell.set(text: text, font: font, color: color, align: align, truncation: truncation)
            return cell
        }

        private func host(_ id: NSUserInterfaceItemIdentifier, tableView: NSTableView,
                          host: String, port: UInt16) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FeedHostCell) ?? FeedHostCell()
            cell.identifier = id
            cell.set(host: host, port: port)
            return cell
        }

        private func badge(_ id: NSUserInterfaceItemIdentifier, tableView: NSTableView,
                           route: Route) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FeedBadgeCell) ?? FeedBadgeCell()
            cell.identifier = id
            cell.set(route: route)
            return cell
        }

        private func dot(_ id: NSUserInterfaceItemIdentifier, tableView: NSTableView,
                         isLive: Bool) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FeedDotCell) ?? FeedDotCell()
            cell.identifier = id
            cell.isLive = isLive
            return cell
        }
    }
}

// MARK: - Cell views

/// Live-connection indicator: a small orange dot centered in the column.
private final class FeedDotCell: NSTableCellView {
    var isLive: Bool = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isLive else { return }
        let side: CGFloat = 6
        let rect = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                          width: side, height: side)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

/// Single-line centered label cell used by most columns.
private final class FeedLabelCell: NSTableCellView {
    private var leftPadding: CGFloat = 3
    private var rightPadding: CGFloat = 3

    func set(text: String, font: NSFont, color: NSColor,
             align: NSTextAlignment, truncation: NSLineBreakMode) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = truncation
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if textField == nil {
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = truncation
            field.maximumNumberOfLines = 1
            addSubview(field)
            textField = field
        }
        textField?.alignment = align
        textField?.lineBreakMode = truncation
        textField?.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        leftPadding = align == .left ? 3 : 1
        rightPadding = align == .right ? 3 : 1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let field = textField else { return }
        let size = field.attributedStringValue.size()
        let height = min(size.height, bounds.height)
        let y = max(0, (bounds.height - height) / 2)
        field.frame = NSRect(x: leftPadding, y: y,
                             width: max(1, bounds.width - leftPadding - rightPadding),
                             height: height)
    }
}

/// Host column: host (middle-truncated) + a `:port` suffix that always stays
/// visible at the trailing edge.
private final class FeedHostCell: NSTableCellView {
    private let hostField = NSTextField(labelWithString: "")
    private let portField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup(hostField, mode: .byTruncatingMiddle)
        setup(portField, mode: .byClipping)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup(hostField, mode: .byTruncatingMiddle)
        setup(portField, mode: .byClipping)
    }

    private func setup(_ field: NSTextField, mode: NSLineBreakMode) {
        field.lineBreakMode = mode
        field.maximumNumberOfLines = 1
        field.isSelectable = false
        addSubview(field)
    }

    func set(host: String, port: UInt16) {
        let hostParagraph = NSMutableParagraphStyle()
        hostParagraph.lineBreakMode = .byTruncatingMiddle
        hostField.attributedStringValue = NSAttributedString(string: host, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: hostParagraph,
        ])
        portField.attributedStringValue = NSAttributedString(string: ":\(port)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Pad the port's width by the label's control inset so the digits are
        // never clipped, then let the host fill (and truncate) the remainder.
        let portWidth = ceil(portField.attributedStringValue.size().width) + 6
        let hostHeight = ceil(hostField.attributedStringValue.size().height)
        let portHeight = ceil(portField.attributedStringValue.size().height)
        portField.frame = NSRect(x: max(0, bounds.width - portWidth - 3),
                                 y: max(0, (bounds.height - portHeight) / 2),
                                 width: portWidth, height: portHeight)
        hostField.frame = NSRect(x: 3, y: max(0, (bounds.height - hostHeight) / 2),
                                 width: max(1, portField.frame.minX - 6), height: hostHeight)
    }
}

/// Route chip (TUNNEL / DIRECT / BLOCK).
private final class FeedBadgeCell: NSTableCellView {
    private let chip = RouteChip(frame: .zero)
    private var tint: NSColor = .systemGray

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(chip)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(chip)
    }

    func set(route: Route) {
        switch route {
        case .tunnel: tint = .systemGreen
        case .direct: tint = .systemGray
        case .block: tint = .systemRed
        }
        chip.tint = tint
        chip.text = route.rawValue
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = chip.intrinsicContentSize
        let width = min(size.width, bounds.width)
        chip.frame = NSRect(x: 3, y: max(0, (bounds.height - size.height) / 2),
                            width: width, height: size.height)
    }
}

/// Draws a capsule chip with a translucent route-colored fill and a bold label.
private final class RouteChip: NSView {
    var text: String = "" { didSet { label.stringValue = text; invalidateIntrinsicContentSize() } }
    var tint: NSColor = .systemGray {
        didSet {
            label.textColor = tint
            needsDisplay = true
        }
    }
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        label.font = .boldSystemFont(ofSize: 10)
        label.alignment = .center
        label.isSelectable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        label.font = .boldSystemFont(ofSize: 10)
        label.alignment = .center
        label.isSelectable = false
        addSubview(label)
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = ceil((text as NSString).size(withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 10),
        ]).width)
        return NSSize(width: textWidth + 10, height: 16)
    }

    override func layout() {
        super.layout()
        let labelSize = label.intrinsicContentSize
        label.frame = NSRect(x: (bounds.width - labelSize.width) / 2,
                             y: (bounds.height - labelSize.height) / 2,
                             width: labelSize.width, height: labelSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}
