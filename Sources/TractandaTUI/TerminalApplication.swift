import CTractandaTerminal
import Foundation
import TractandaCore

private enum PickerPurpose {
    case categories, views, sections, include, exclude, reset, explain, history, parent, batchCategory,
        learning, breadcrumb, completionCategory, viewIncludedCategories, viewExcludedCategories

    var isViewCategoryCriteria: Bool {
        self == .viewIncludedCategories || self == .viewExcludedCategories
    }
}
private struct Picker {
    struct Items: RandomAccessCollection {
        typealias Index = Int
        var treeRows: CategoryTree.Rows?
        var items: [Revision] = []
        var startIndex: Int { 0 }
        var endIndex: Int { treeRows?.count ?? items.count }
        func index(after i: Int) -> Int { i + 1 }
        func index(before i: Int) -> Int { i - 1 }
        subscript(index: Int) -> Revision { treeRows?[index].item ?? items[index] }
    }
    let id = Identifier.make()
    let purpose: PickerPurpose
    let source: [Revision]
    let base: Revision?
    var filter = TextBuffer() {
        didSet { if oldValue.text != filter.text { updateRows() } }
    }
    var index = 0
    var firstVisibleIndex = 0
    var selected: [Revision] = []
    let tree: CategoryTree?
    var expanded: Set<String> = [] {
        didSet { if oldValue != expanded { updateRows() } }
    }
    private(set) var treeRows = CategoryTree.Rows()
    var matches: Items {
        if tree != nil { return Items(treeRows: treeRows) }
        if purpose == .history { return Items(items: source) }
        return Items(
            items: source.filter {
                filter.text.isEmpty || title($0).localizedCaseInsensitiveContains(filter.text)
            })
    }
    init(
        purpose: PickerPurpose, source: [Revision], base: Revision?, selected: [Revision] = [],
        tree: CategoryTree? = nil
    ) {
        self.purpose = purpose
        self.source = source
        self.base = base
        self.selected = selected
        self.tree = tree
        expanded = tree?.initialExpansion ?? []
        updateRows()
    }
    private mutating func updateRows() {
        treeRows = tree?.rows(filter: filter.text, expanded: expanded) ?? CategoryTree.Rows()
    }
    mutating func toggleBranch(at index: Int) {
        guard treeRows.indices.contains(index) else { return }
        let row = treeRows[index]
        guard row.hasChildren else { return }
        if !filter.text.isEmpty {
            // Switch from deduplicated search to the selected real placement, without a jump.
            var revealed = expanded
            for depth in 1...row.path.count {
                revealed.insert(row.path.prefix(depth).map(\.itemID).joined(separator: "/"))
            }
            expanded = revealed
            filter = TextBuffer()
            self.index = treeRows.index(ofPath: row.path.map(\.itemID)) ?? 0
        } else if !expanded.insert(row.key).inserted {
            expanded.remove(row.key)
        }
    }
    func title(_ item: Revision) -> String {
        let name = item.fields["subject"]?.string ?? item.itemID
        if purpose == .history { return item.modifiedAt + "  " + name }
        if purpose == .breadcrumb, let index = source.firstIndex(where: { $0.itemID == item.itemID }) {
            return "\(index + 1)  " + name
        }
        return name
    }
}
private enum FormPurpose {
    case item(ItemDraft)
    case filter
    case saveView(replacing: Bool)
    case viewDefinition
    case sort([ItemSort])
    case column(Int?)
    case deleteCategory(Revision)
    case batch(BatchOperation)
    case learningSettings(LearningSettingsDraft)
    case appearance(TerminalAppearance)
    case appearanceName(TerminalAppearance)
    case categoryPreferences(Bool)
    case learningFilter
    case resetLearning(String)
    case categoryDirty

    var isSettings: Bool {
        switch self {
        case .appearance, .appearanceName, .categoryPreferences: true
        default: false
        }
    }
}

private enum CategoryDirtyAction {
    case select([Revision])
    case close
    case open
    case refine
    case command(TUICommand)
}
private struct CategoryPageSelection {
    let itemID: String?
    let index: Int
    let firstVisible: Int
}
private struct Form {
    let id = Identifier.make()
    let purpose: FormPurpose
    let title: String
    var fields: [TextBuffer]
    let labels: [String]
    var focus = 0
    var scrollOffset: Int?
    func isMultiline(_ index: Int) -> Bool {
        if case .item = purpose { return index == 1 }
        return false
    }
}

/// The Appearance form is deliberately a flat form buffer so it has no persistence schema of its
/// own.  Keep its ephemeral order in one place: the renderer, validation and selector paths must
/// agree or a cursor change can accidentally alter a colour role.
private enum AppearanceFormField {
    static let preset = 0
    static let cursorLayout = 1
    static let cursorShape = 2
    static let cursorColor = 3
    static let cursorBlink = 4
    static let shadows = 5
    static let firstRole = 6

    static var count: Int { firstRole + AppearanceRole.allCases.count * 2 }

    static func foreground(_ roleIndex: Int) -> Int { firstRole + roleIndex * 2 }
    static func background(_ roleIndex: Int) -> Int { foreground(roleIndex) + 1 }
    static func isRole(_ index: Int) -> Bool { (firstRole..<count).contains(index) }
    static func isColor(_ index: Int) -> Bool {
        index == cursorColor || isRole(index)
    }
    static func section(for index: Int) -> String {
        index <= preset
            ? "Appearance preset"
            : index <= cursorBlink ? "Cursor" : index == shadows ? "Effects" : "Interface colors"
    }
}
private struct ViewDefinitionDraft {
    let original: WorkspaceLocation
    let selectedItemID: String?
    let selectedRow: Int
    let firstVisibleRow: Int
    let columnOffset: Int
    let isNew: Bool
    var form: ViewDefinitionForm
}
enum ScreenStyle: Equatable {
    case normal, activePane, title, header, activeSelection, inactiveSelection, textSelection, dimmed, shadow,
        key,
        functionKeyLabel
    case menu, menuSelection, disabled, link

    /// Portable SGR attributes.  Selection deliberately owns a navy background while headers only
    /// use bold text on the terminal's normal background.
    func escape(using appearance: TerminalAppearance) -> String {
        switch self {
        case .normal: "\u{1b}[0m"
        case .activePane: appearance.sgr(for: .activePane)
        case .title: appearance.sgr(for: .titleBar)
        case .header: appearance.sgr(for: .heading)
        case .activeSelection: appearance.sgr(for: .activeSelection)
        case .inactiveSelection: appearance.sgr(for: .inactiveSelection)
        case .textSelection: "\u{1b}[7m"
        case .dimmed: appearance.sgr(for: .passivePane)
        case .shadow: "\u{1b}[0;2;30;40m"
        case .key: appearance.sgr(for: .functionKeyNumber)
        case .menu: appearance.sgr(for: .menuSurface)
        case .functionKeyLabel: appearance.sgr(for: .functionKeyLabel)
        case .menuSelection: appearance.sgr(for: .menuSelection)
        case .disabled: appearance.sgr(for: .menuSurface).replacingOccurrences(of: "[0;", with: "[0;2;")
        case .link: "\u{1b}[0;4m"
        }
    }
}

struct ScreenCell: Equatable {
    let style: ScreenStyle
}

/// Keeps ANSI emission and the cell attributes asserted by tests in one place.  A line has one
/// semantic style unless it supplies explicit segments, which makes split-pane boundaries exact.
enum TerminalANSI {
    static func line(_ line: ScreenLine, columns: Int, appearance: TerminalAppearance) -> String {
        let runs = line.segments.isEmpty ? [ScreenSegment(text: line.text, style: line.style)] : line.segments
        var result = ""
        var column = 0
        for run in runs {
            var style = run.style
            result += style.escape(using: appearance)
            for character in TerminalText.safe(run.text) {
                let width = TerminalText.width(character)
                guard column + width <= columns else { break }
                let selected = line.selectionColumns.contains { $0.overlaps(column..<(column + width)) }
                // Popup callers declare their frame cells explicitly. Selection and row styles
                // apply only to the panel interior, never to its box drawing characters.
                let framed = line.borderColumns.contains { $0.overlaps(column..<(column + width)) }
                let shadowed = line.shadowColumns.contains { $0.overlaps(column..<(column + width)) }
                let desired: ScreenStyle =
                    shadowed ? .shadow : (framed ? line.borderStyle : (selected ? .textSelection : run.style))
                if desired != style {
                    result += desired.escape(using: appearance)
                    style = desired
                }
                result.append(character)
                column += width
                if column >= columns { break }
            }
            if column >= columns { break }
        }
        if column < columns {
            var paddingStyle: ScreenStyle?
            for cell in column..<columns {
                let desired: ScreenStyle =
                    line.shadowColumns.contains { $0.contains(cell) }
                    ? .shadow : line.style
                if desired != paddingStyle {
                    result += desired.escape(using: appearance)
                    paddingStyle = desired
                }
                result.append(" ")
            }
        }
        return result + "\u{1b}[0m\u{1b}[K"
    }

    static func cells(_ line: ScreenLine, columns: Int) -> [ScreenCell] {
        guard columns > 0 else { return [] }
        let runs =
            line.segments.isEmpty ? [(line.text, line.style)] : line.segments.map { ($0.text, $0.style) }
        var result: [ScreenCell] = []
        var column = 0
        for (text, style) in runs {
            for character in text {
                let width = TerminalText.width(character)
                guard width > 0 else { continue }
                guard result.count + width <= columns else { return result }
                let framed = line.borderColumns.contains { $0.overlaps(column..<(column + width)) }
                let selected = line.selectionColumns.contains { $0.overlaps(column..<(column + width)) }
                let shadowed = line.shadowColumns.contains { $0.overlaps(column..<(column + width)) }
                let cellStyle: ScreenStyle =
                    shadowed ? .shadow : (framed ? line.borderStyle : (selected ? .textSelection : style))
                result += Array(repeating: ScreenCell(style: cellStyle), count: width)
                column += width
            }
        }
        let trailing =
            line.segments.isEmpty ? line.style : (line.style == .activePane ? .activePane : .normal)
        for column in result.count..<columns {
            let style: ScreenStyle = line.shadowColumns.contains { $0.contains(column) } ? .shadow : trailing
            result.append(ScreenCell(style: style))
        }
        return result
    }
}

struct ScreenLine {
    var text: String
    var style: ScreenStyle = .normal
    var segments: [ScreenSegment] = []
    var hits: [MouseHit] = []
    var selectionColumns: [Range<Int>] = []
    /// Cell-only popup shadow spans.  They deliberately retain the rendered glyphs and hits.
    var shadowColumns: [Range<Int>] = []
    /// Box frames are specified by panel renderers; body glyphs are never inferred as borders.
    var borderColumns: [Range<Int>] = []
    var borderStyle: ScreenStyle = .menu
    /// A zero-based terminal cell.  It is deliberately separate from the display glyphs.
    var cursorColumn: Int?

    static func controls(
        _ controls: [(String, TUICommand)], prefix: String = "", style: ScreenStyle = .normal
    )
        -> ScreenLine
    {
        var text = " " + prefix + (prefix.isEmpty || controls.isEmpty ? "" : " · ")
        var hits: [MouseHit] = []
        for (index, entry) in controls.enumerated() {
            if index > 0 { text += " · " }
            let start = text.reduce(0) { $0 + TerminalText.width($1) }
            text += entry.0
            let end = text.reduce(0) { $0 + TerminalText.width($1) }
            hits.append(MouseHit(columns: start..<end, target: .command(entry.1)))
        }
        return ScreenLine(text: text, style: style, hits: hits)
    }
}
struct ScreenSegment {
    let text: String
    let style: ScreenStyle
}
/// Explicit panel geometry lets the compositor style a shadow without inspecting box glyphs.
struct OverlayRect: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}
private struct HardwareCursor: Equatable {
    let row: Int
    let column: Int
}
private struct AppliedCursor: Equatable {
    let preferences: CursorPreferences
    let capturedColor: String?
}

/// Synchronous terminal controller. A resize changes only rendering, never navigation or draft state.
public final class TerminalApplication {
    private enum PrimaryWorkspace { case views, categories }
    private let workspace: Workspace
    private let journal: RecoveryJournal
    private let keymap: Keymap
    private let clipboard = TextClipboard()
    private var input = TerminalInput()
    private var picker: Picker?
    private var form: Form?
    private var columnEditor: ColumnEditor?
    private var columnOffset = 0
    private var pending: PendingEdit?
    private var pendingBatch: BatchOperation?
    private var pendingLearning: LearningEdit?
    private var learning: LearningWorkspace?
    private var marks = MarkedItems()
    private var navigationHistory = NavigationHistory()
    private var isBatchMenuOpen = false
    private var batchAction: BatchOperation.Action?
    private var panel: (title: String, text: String)?
    private var panelOffset = 0
    private var menu: CommandMenu?
    private var childMenu: CategoryChildrenMenu?
    private var isMenuOpen: Bool { menu != nil || childMenu != nil }
    private var functionKeys: FunctionKeyDisplay
    private var menuContext = KeyContext.browser
    private var itemIndex = 0
    private var firstVisibleItem = 0
    private var firstVisibleColumn = 0
    private var status = "Ready"
    private var isRunning = true
    private var columns = 80
    private var rows = 24
    private var lastClockRefresh = Date()
    private var isMouseEnabled: Bool
    private var mouse = MouseGesture()
    private var mouseLines: [ScreenLine] = []
    private var mouseFrameSize = (columns: 0, rows: 0)
    private var mouseFrameScene = ""
    private var menuID = Identifier.make()
    private var editorViewport: (field: Int, offset: Int, maximum: Int)?
    private var viewWorkspace: Picker?
    private var viewWorkspaceFocused = true
    private var viewPreviewFocused = false
    private var viewPreviewOffset = 0
    private var categoryPreviewFocused = false
    private var categoryPreviewOffset = 0
    private var viewPreviewItemID: String?
    private var categoryPreviewItemID: String?
    private var categoryBreadcrumbReturnPicker: Picker?
    private var categoryToolReturnPicker: Picker?
    /// Category preview lives alongside the picker, never in the report Workspace.  That is what
    /// lets a highlight remain a harmless preview until Return explicitly opens the path.
    private var categoryWorkspace: CategoryWorkspace?
    // Category reports keep their own presentation intent. A saved View may change columns or
    // sorting without silently restyling/reordering the retained Categories workspace.
    private var categoryReportColumns = ViewPresentation.defaultColumns
    private var categoryReportSort: [ItemSort] = []
    // Categories is a primary workspace, but its data model is still the existing lazy picker.
    // Swap it out while Views is visible so picker context cannot masquerade as a third screen.
    private var retainedCategoryPicker: Picker?
    private var retainedCategoryWorkspace: CategoryWorkspace?
    private var activeWorkspace: PrimaryWorkspace = .views
    private var suspendedForm: Form?
    private let categoryPreviewLoader: CategoryPreviewLoader?
    private var categoryPreviewGeneration = 0
    private var categoryPageSelection: (generation: Int, value: CategoryPageSelection)?
    private var categoryDirtyAction: CategoryDirtyAction?
    /// Proposed search/expansion stays detached until the user accepts a dirty transition.
    private var categoryDirtyPicker: Picker?
    private var categoryDirtyPickerOriginID: String?
    private var categoryInspectorViewport: (field: Int, start: Int, maximum: Int)?
    private var categoryInspectorTextWidth = 40
    private var viewSelectorVisible = true
    private let viewPreferencesURL: URL
    private var viewPreferences = ViewWorkspacePreferences()
    /// Dragging previews the requested height in memory; release performs the one private save.
    private var previewDragContentHeight: Int?
    private var renderedReportPageHeight = 1
    private let appearanceURL: URL
    private var appearance = TerminalAppearance.initial()
    private var appearanceFormBeforeNaming: Form?
    private var viewDefinitionDraft: ViewDefinitionDraft?
    private var capturedCursorStyle: Int?
    private var capturedCursorColor: String?

    private var previewVisible: Bool { viewPreferences.previewVisible }
    private var effectivePreviewContentRows: Int {
        ItemPreviewPresentation.effectiveContentRows(
            preferred: previewDragContentHeight ?? viewPreferences.previewContentHeight, terminalRows: rows)
    }

    public convenience init(
        socketPath: String, recoveryURL: URL? = nil, viewID: String? = nil, itemsOnly: Bool = false,
        viewPreferencesURL: URL? = nil, appearanceURL: URL? = nil,
        functionKeys: FunctionKeyDisplay = .automatic, mouseEnabled: Bool = true
    ) throws {
        let connection = try ConnectionPreferences().resolve(socketPath: socketPath)
        try self.init(
            connection: connection, recoveryURL: recoveryURL, viewID: viewID, itemsOnly: itemsOnly,
            viewPreferencesURL: viewPreferencesURL, appearanceURL: appearanceURL, functionKeys: functionKeys,
            mouseEnabled: mouseEnabled)
    }

    public convenience init(
        connection: ServerConnection, recoveryURL: URL? = nil, viewID: String? = nil, itemsOnly: Bool = false,
        viewPreferencesURL: URL? = nil, appearanceURL: URL? = nil,
        functionKeys: FunctionKeyDisplay = .automatic, mouseEnabled: Bool = true
    )
        throws
    {
        let socketPath = connection.socketPath
        guard !socketPath.isEmpty, socketPath.utf8.count <= 103, !socketPath.contains("\0") else {
            throw TractandaError("invalidSocketPath", "Use a Unix socket path of 1–103 UTF-8 bytes.")
        }
        let client = ItemClient(connection: connection)
        let stateDirectory = Self.defaultStateDirectory()
        let primaryJournalURL = RecoveryJournal.defaultURL(socket: socketPath, stateDirectory: stateDirectory)
        let usesDefaultJournal = recoveryURL == nil
        let journal: RecoveryJournal
        if let recoveryURL {
            // An explicitly named journal remains strict: a second client receives its busy error.
            journal = RecoveryJournal(
                url: recoveryURL, socket: socketPath, serviceUser: connection.serverUser)
        } else {
            journal = try RecoveryJournal.claimDefault(
                primaryURL: primaryJournalURL, socket: socketPath, serviceUser: connection.serverUser)
        }
        let resolvedAppearanceURL =
            appearanceURL
            ?? stateDirectory.appendingPathComponent("appearance.json")
        try self.init(
            client: client, journal: journal, viewID: viewID, itemsOnly: itemsOnly,
            viewPreferencesURL: viewPreferencesURL
                ?? (usesDefaultJournal
                    ? RecoveryJournal.defaultViewPreferencesURL(for: primaryJournalURL) : nil),
            appearanceURL: resolvedAppearanceURL,
            previewConnection: connection, functionKeys: functionKeys,
            mouseEnabled: mouseEnabled)
    }

    private static func defaultStateDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["TRACTANDA_TUI_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/tractanda/tui")
    }

    init(
        client: ItemClient, journal: RecoveryJournal, viewID: String? = nil, itemsOnly: Bool = false,
        viewPreferencesURL: URL? = nil, appearanceURL: URL? = nil, keymap: Keymap = .standard,
        previewConnection: ServerConnection? = nil,
        functionKeys: FunctionKeyDisplay = .automatic, mouseEnabled: Bool = true
    )
        throws
    {
        workspace = Workspace(client: client)
        self.journal = journal
        self.keymap = keymap
        self.viewPreferencesURL =
            viewPreferencesURL
            ?? journal.url
            .deletingPathExtension().appendingPathExtension("views.json")
        self.appearanceURL =
            appearanceURL
            ?? journal.url.deletingPathExtension().appendingPathExtension("appearance.json")
        self.functionKeys = functionKeys
        self.isMouseEnabled = mouseEnabled
        categoryPreviewLoader = previewConnection.map(CategoryPreviewLoader.init(connection:))
        if let operation = try journal.loadOperation() {
            switch operation {
            case .single(let request):
                pending = PendingEdit(request)
                status = "Recovered unconfirmed edit. R retries the same request; Q quits and keeps it."
            case .batch(let batch):
                pendingBatch = batch
                status = "Recovered group operation. R resumes the saved requests; Q keeps recovery."
            case .learning(let edit):
                pendingLearning = edit
                status = "Recovered unconfirmed learning edit. R retries exactly; Q keeps recovery."
            }
        }
        if let viewID { try workspace.openView(client.revision(for: viewID)) }
        do { try workspace.refresh() } catch { status = String(describing: error) }
        viewSelectorVisible = !itemsOnly
        // A named view opens its report immediately while retaining the selector for later choices.
        viewWorkspaceFocused = !itemsOnly && viewID == nil
        do { viewPreferences = try ViewWorkspacePreferences.load(from: self.viewPreferencesURL) } catch {
            status = String(describing: error)
        }
        if !itemsOnly {
            do { try reloadViewWorkspace() } catch { status = String(describing: error) }
        }
        do { appearance = try TerminalAppearance.load(from: self.appearanceURL) } catch {
            status = String(describing: error)
        }
    }

    /// Opens raw mode only after argument/recovery validation, and restores it on every handled exit.
    public func run() throws {
        guard ProcessInfo.processInfo.environment["TERM"] != "dumb", tractanda_terminal_open() == 0 else {
            throw TractandaError("terminalRequired", "Run tractanda-tui in an interactive UTF-8 terminal.")
        }
        defer {
            _ = write(
                TerminalCursorProtocol.restore(style: capturedCursorStyle, color: capturedCursorColor)
                    + TerminalMouseReporting.restore
                    + "\u{1b}[<u\u{1b}[0m\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l")
            tractanda_terminal_close()
        }
        guard
            write(
                "\u{1b}[?1049h\u{1b}[>1u\u{1b}[?25l\u{1b}[?2004h" + TerminalMouseReporting.save
                    + TerminalMouseReporting.configure(enabled: isMouseEnabled))
        else { return }
        // Query only while this raw session owns input.  Replies are bounded and stripped by
        // TerminalInput, so a fragmented or late OSC/DCS response can never become editor text.
        _ = write(TerminalCursorProtocol.query)
        var reportedMouse = isMouseEnabled
        var reportedHover = false
        var previousFrame = ""
        var previousCursor: HardwareCursor?
        var appliedCursor: AppliedCursor?
        let cursorCaptureDeadline = Date().addingTimeInterval(0.25)
        var needsRender = true
        while isRunning {
            let reportHover = isMouseEnabled && keyContext == .menu
            if reportedMouse != isMouseEnabled || reportedHover != reportHover {
                guard write(TerminalMouseReporting.configure(enabled: isMouseEnabled, hover: reportHover))
                else { break }
                reportedMouse = isMouseEnabled
                reportedHover = reportHover
            }
            var width: Int32 = 80
            var height: Int32 = 24
            tractanda_terminal_size(&width, &height)
            let newColumns = min(400, max(1, Int(width)))
            let newRows = min(200, max(1, Int(height)))
            needsRender = needsRender || columns != newColumns || rows != newRows
            columns = newColumns
            rows = newRows
            if categoryPreviewLoader?.hasDelivery() == true { needsRender = true }
            if Date().timeIntervalSince(lastClockRefresh) >= 30,
                form == nil, picker == nil, pending == nil, pendingBatch == nil, pendingLearning == nil,
                panel == nil,
                learning == nil,
                columnEditor == nil, !isMenuOpen, !isBatchMenuOpen
            {
                lastClockRefresh = Date()
                let selectedID = current?.itemID
                execute {
                    try workspace.refresh()
                    itemIndex =
                        selectedID.flatMap { id in workspace.rows.firstIndex { $0.item?.itemID == id } } ?? 0
                }
                needsRender = true
            }
            if needsRender {
                let rendered = render(columns: columns, rows: rows)
                let cursor = rendered.enumerated().compactMap { row, line in
                    line.cursorColumn.map { HardwareCursor(row: row, column: $0) }
                }.last
                let frame = rendered.map {
                    TerminalANSI.line($0, columns: max(0, columns - 1), appearance: appearance)
                }.joined(separator: "\r\n")
                let desiredCursor = cursor.map { _ in
                    AppliedCursor(preferences: appearance.cursor, capturedColor: capturedCursorColor)
                }
                if frame != previousFrame || cursor != previousCursor || desiredCursor != appliedCursor {
                    var output = frame == previousFrame ? "" : "\u{1b}[H" + frame
                    if let cursor {
                        if desiredCursor != appliedCursor {
                            output += TerminalCursorProtocol.apply(
                                appearance.cursor, capturedColor: capturedCursorColor)
                        }
                        output += "\u{1b}[\(cursor.row + 1);\(cursor.column + 1)H\u{1b}[?25h"
                    } else {
                        output += "\u{1b}[?25l"
                    }
                    guard write(output) else { break }
                    previousFrame = frame
                    previousCursor = cursor
                    appliedCursor = desiredCursor
                }
                needsRender = false
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = tractanda_terminal_read(&buffer, buffer.count, input.isAwaitingEscape ? 80 : 150)
            if count < 0 { break }
            let keys = input.receive(
                count == 0 ? [] : Array(buffer.prefix(Int(count))), expireEscape: count == 0)
            var receivedTerminalReply = false
            for reply in input.takeTerminalReplies() {
                let snapshot = TerminalCursorProtocol.parse(reply)
                if Date() <= cursorCaptureDeadline, capturedCursorStyle == nil, let style = snapshot.style {
                    capturedCursorStyle = style
                    receivedTerminalReply = true
                }
                if Date() <= cursorCaptureDeadline, capturedCursorColor == nil, let color = snapshot.color {
                    capturedCursorColor = color
                    receivedTerminalReply = true
                }
            }
            for key in keys { handle(key) }
            needsRender = !keys.isEmpty || receivedTerminalReply
        }
    }

    private func write(_ text: String) -> Bool {
        let data = Data(text.utf8)
        return data.withUnsafeBytes { tractanda_terminal_write($0.baseAddress, $0.count) == 0 }
    }

    private var current: Revision? {
        currentRow?.item
    }
    private var currentRow: WorkspaceRow? {
        let rows = workspace.rows
        return rows.indices.contains(itemIndex) ? rows[itemIndex] : nil
    }
    private var pageHeight: Int { max(1, rows - (columns >= 110 ? 7 : 12)) }
    private var isCompactViewWorkspace: Bool {
        viewSelectorVisible && viewWorkspace != nil && rows < 24
    }
    /// Updated by the actual Views renderer, including side-by-side selector and preview geometry.
    private var reportPageHeight: Int { max(1, renderedReportPageHeight) }

    private func reloadViewWorkspace() throws {
        let previous = viewWorkspace
        let previousFilter = previous?.filter
        let previousSelectedID = previous.flatMap { selector in
            selector.matches.indices.contains(selector.index) ? selector.matches[selector.index].itemID : nil
        }
        let views = try workspace.views().filter { !$0.isDeleted }
        let pins = Set(viewPreferences.pinnedViewIDs)
        let ordered = views.sorted {
            let leftPinned = pins.contains($0.itemID)
            let rightPinned = pins.contains($1.itemID)
            if leftPinned != rightPinned { return leftPinned }
            let left = $0.fields["subject"]?.string ?? $0.itemID
            let right = $1.fields["subject"]?.string ?? $1.itemID
            let compared = left.localizedCaseInsensitiveCompare(right)
            return compared == .orderedSame ? $0.itemID < $1.itemID : compared == .orderedAscending
        }
        var selector = Picker(purpose: .views, source: ordered, base: nil)
        if let previousFilter { selector.filter = previousFilter }
        let selectedID = workspace.view?.itemID ?? previousSelectedID
        selector.index =
            selectedID.flatMap { id in
                selector.matches.firstIndex { $0.itemID == id }
            } ?? -1
        viewWorkspace = selector  // -1 is the implicit All items entry.
    }

    private func selectWorkspaceView() throws {
        guard let selector = viewWorkspace else { return }
        if selector.index < 0 {
            try navigate { try workspace.allItems() }
            status = "All readable items"
        } else if selector.matches.indices.contains(selector.index) {
            let selected = selector.matches[selector.index]
            do {
                let current = try workspace.client.revision(for: selected.itemID)
                try navigate { try workspace.openView(current) }
                status = "Opened " + (current.fields["subject"]?.string ?? current.itemID)
            } catch {
                workspace.clearResults()
                throw error
            }
        }
        itemIndex = 0
        firstVisibleItem = 0
        columnOffset = 0
    }

    private func enterCategoriesWorkspace() throws {
        guard activeWorkspace != .categories else { return }
        let previous = retainedCategoryPicker
        let manager = retainedCategoryWorkspace
        // Rebuild through the current ACL rather than trusting a retained catalog. Preserve only
        // local presentation intent and editable draft state.
        try beginPicker(.categories)
        if var fresh = picker, let previous {
            fresh.filter = previous.filter
            fresh.expanded = previous.expanded
            let selectedID =
                previous.matches.indices.contains(previous.index)
                ? previous.matches[previous.index].itemID : nil
            if let selectedID, let index = fresh.matches.firstIndex(where: { $0.itemID == selectedID }) {
                fresh.index = index
            }
            picker = fresh
        }
        if let manager {
            categoryWorkspace = manager
            let selectedItem =
                manager.preview.rows.indices.contains(manager.previewIndex)
                ? manager.preview.rows[manager.previewIndex].itemID : nil
            let selection = CategoryPageSelection(
                itemID: selectedItem, index: manager.previewIndex, firstVisible: manager.previewFirstVisible)
            let path = manager.selectedPath.map(\.itemID)
            if path.isEmpty {
                selectCategoryWorkspacePath([], position: manager.preview.position, selection: selection)
            } else if let index = picker?.treeRows.index(ofPath: path), let row = picker?.treeRows[index] {
                picker?.index = index
                selectCategoryWorkspacePath(
                    row.path, position: manager.preview.position, selection: selection)
            } else {
                categoryWorkspace?.selectedAllItems = true
                selectCategoryWorkspacePath([])
                status = "Selected category is no longer readable; showing All items."
            }
        }
        activeWorkspace = .categories
        status = "Categories workspace"
    }

    private func leaveCategoriesWorkspace() {
        guard activeWorkspace == .categories else { return }
        retainedCategoryPicker = picker
        retainedCategoryWorkspace = categoryWorkspace
        saveCategoryWorkspacePreferences()
        picker = nil
        categoryWorkspace = nil
        activeWorkspace = .views
        viewSelectorVisible = true
        status = "Views workspace"
    }

    private func switchWorkspace(to target: PrimaryWorkspace? = nil) {
        let destination = target ?? (activeWorkspace == .views ? .categories : .views)
        execute {
            switch destination {
            case .views: leaveCategoriesWorkspace()
            case .categories: try enterCategoriesWorkspace()
            }
        }
    }

    private func toggleItemPreview() {
        viewPreferences.previewVisible.toggle()
        do { try viewPreferences.save(to: viewPreferencesURL) } catch {
            viewPreferences.previewVisible.toggle()
            status = String(describing: error)
            return
        }
        if !viewPreferences.previewVisible {
            viewPreviewFocused = false
            categoryPreviewFocused = false
        }
        status = viewPreferences.previewVisible ? "Item preview shown." : "Item preview hidden."
    }

    private func resizeItemPreview(by delta: Int? = nil, reset: Bool = false) {
        let previous = viewPreferences.previewContentHeight
        viewPreferences.previewContentHeight =
            reset
            ? ItemPreviewPresentation.defaultContentRows
            : min(1_000, max(1, previous + (delta ?? 0)))
        guard viewPreferences.previewContentHeight != previous else { return }
        do { try viewPreferences.save(to: viewPreferencesURL) } catch {
            viewPreferences.previewContentHeight = previous
            status = String(describing: error)
            return
        }
        status =
            reset
            ? "Item preview reset to 3 rows."
            : "Item preview requests \(viewPreferences.previewContentHeight) rows."
    }

    private func resizeItemPreview(toPointerRow row: Int) {
        previewDragContentHeight = min(
            1_000,
            ItemPreviewPresentation.requestedContentRows(terminalRows: rows, dividerRow: row))
    }

    private func savePreviewDrag() {
        guard let requested = previewDragContentHeight else { return }
        previewDragContentHeight = nil
        let previous = viewPreferences.previewContentHeight
        viewPreferences.previewContentHeight = requested
        guard requested != previous else { return }
        do { try viewPreferences.save(to: viewPreferencesURL) } catch {
            viewPreferences.previewContentHeight = previous
            status = String(describing: error)
        }
    }

    private var isMainWorkspaceInput: Bool {
        form == nil && panel == nil && columnEditor == nil && learning == nil
            && !isMenuOpen && !isBatchMenuOpen && pending == nil && pendingBatch == nil
            && pendingLearning == nil && (picker == nil || picker?.purpose == .categories)
    }

    private var isBottomPreviewVisible: Bool { previewVisible && columns >= 48 && rows >= 24 }

    /// These actions require an item list or editor to own focus; previewing must not target an
    /// inspector left open in another pane. Keyboard aliases and F10 use the same boundary.
    private static let previewEditingCommands: Set<TUICommand> = [
        .editItem, .editView, .editNote, .properties, .include, .exclude, .reset, .explain,
        .history, .done, .mark, .unmarkAll, .selectAll, .group, .reviewMarks, .deleteItems,
        .save, .saveAs, .copy, .cut, .paste, .undo, .redo, .setMark, .selectText,
    ]

    private var activePreviewItem: Revision? {
        if activeWorkspace == .categories, let manager = categoryWorkspace {
            return selectedCategoryItem(manager)
        }
        return current
    }

    private var activePreviewFocused: Bool {
        get { activeWorkspace == .views ? viewPreviewFocused : categoryPreviewFocused }
        set {
            if activeWorkspace == .views {
                viewPreviewFocused = newValue
            } else {
                categoryPreviewFocused = newValue
            }
        }
    }

    private var activePreviewOffset: Int {
        get { activeWorkspace == .views ? viewPreviewOffset : categoryPreviewOffset }
        set {
            if activeWorkspace == .views {
                viewPreviewOffset = newValue
            } else {
                categoryPreviewOffset = newValue
            }
        }
    }

    private func scrollItemPreview(by delta: Int? = nil, toEnd: Bool = false) {
        let maximum = ItemPreviewPresentation.maximumOffset(
            item: activePreviewItem, width: max(1, columns - 1), contentRows: effectivePreviewContentRows)
        let current = min(maximum, max(0, activePreviewOffset))
        activePreviewOffset = toEnd ? maximum : min(maximum, max(0, current + (delta ?? -current)))
    }

    private func focusAfterPreview(navigator: Bool) {
        activePreviewFocused = false
        if activeWorkspace == .views {
            viewWorkspaceFocused = navigator
            if navigator { viewSelectorVisible = true }
        } else {
            categoryWorkspace?.focus = navigator ? .navigator : .right
            if !navigator, categoryWorkspace?.rightMode == .category {
                categoryWorkspace?.inspector?.focus = 3
            }
        }
    }

    private func handlePreviewInput(_ key: TerminalKey) -> Bool {
        guard isMainWorkspaceInput, isBottomPreviewVisible, activePreviewFocused else { return false }
        let mainContext: KeyContext = activeWorkspace == .categories ? .categories : .browser
        let mainCommand = keymap.command(for: key, in: mainContext)
        if mainCommand == .toggleSelector {
            focusAfterPreview(navigator: true)
            return true
        }
        let shared: Set<TUICommand> = [
            .help, .commands, .appearance, .categoryPreferences, .refresh, .switchWorkspace, .togglePreview,
            .growPreview, .shrinkPreview, .resetPreview, .toggleSelector, .focusReport,
        ]
        if let mainCommand, shared.contains(mainCommand) {
            dispatch(mainCommand, key: key, context: mainContext)
            return true
        }
        if let mainCommand, Self.previewEditingCommands.contains(mainCommand) { return true }
        // The preview is read-only.  Contextual function keys must not edit an inactive list.
        if case .function(let number) = key, (2...7).contains(number) { return true }
        switch keymap.command(for: key, in: .reader) {
        case .moveUp: scrollItemPreview(by: -1)
        case .moveDown: scrollItemPreview(by: 1)
        case .pageUp: scrollItemPreview(by: -effectivePreviewContentRows)
        case .pageDown: scrollItemPreview(by: effectivePreviewContentRows)
        case .first: scrollItemPreview()
        case .last: scrollItemPreview(toEnd: true)
        case .cancel: focusAfterPreview(navigator: true)
        default:
            if key == .tab {
                focusAfterPreview(navigator: true)
            } else if key == .backTab {
                focusAfterPreview(navigator: false)
            } else {
                return false
            }
        }
        return true
    }

    private func toggleWorkspacePin() throws {
        guard let selector = viewWorkspace, selector.matches.indices.contains(selector.index) else {
            throw TractandaError("selection", "Select a saved view to pin it.")
        }
        let id = selector.matches[selector.index].itemID
        let previous = viewPreferences.pinnedViewIDs
        if let index = viewPreferences.pinnedViewIDs.firstIndex(of: id) {
            viewPreferences.pinnedViewIDs.remove(at: index)
            status = "View unpinned locally."
        } else {
            viewPreferences.pinnedViewIDs.append(id)
            status = "View pinned locally."
        }
        do { try viewPreferences.save(to: viewPreferencesURL) } catch {
            viewPreferences.pinnedViewIDs = previous
            throw error
        }
        try reloadViewWorkspace()
    }

    private func handleViewWorkspace(_ key: TerminalKey) -> Bool {
        if !viewSelectorVisible, form == nil, picker == nil, columnEditor == nil, panel == nil,
            !isMenuOpen, learning == nil, !isBatchMenuOpen,
            keymap.command(for: key, in: .browser) == .toggleSelector
        {
            viewSelectorVisible = true
            viewWorkspaceFocused = true
            status = "View selector restored."
            return true
        }
        guard viewSelectorVisible, form == nil, picker == nil, columnEditor == nil, panel == nil,
            !isMenuOpen, learning == nil, !isBatchMenuOpen
        else { return false }
        if case .tab = key {
            if viewWorkspaceFocused {
                viewWorkspaceFocused = false
            } else if !viewPreviewFocused, isBottomPreviewVisible {
                viewPreviewFocused = true
            } else {
                viewPreviewFocused = false
                viewWorkspaceFocused = true
            }
            return true
        }
        if case .backTab = key {
            if viewWorkspaceFocused, isBottomPreviewVisible {
                viewWorkspaceFocused = false
                viewPreviewFocused = true
            } else {
                viewWorkspaceFocused.toggle()
            }
            return true
        }
        let command = keymap.command(for: key, in: viewWorkspaceFocused ? .viewWorkspace : .browser)
        if performViewWorkspaceCommand(command) { return true }
        guard viewWorkspaceFocused, var selector = viewWorkspace, command == nil else { return false }
        let before = selector.filter.text
        selector.filter.handle(key, clipboard: clipboard, keymap: keymap)
        if before != selector.filter.text {
            selector.index =
                selector.matches.firstIndex {
                    selector.title($0).localizedCaseInsensitiveContains(selector.filter.text)
                } ?? -1
        }
        viewWorkspace = selector
        if before != selector.filter.text {
            let selectedID =
                selector.matches.indices.contains(selector.index)
                ? selector.matches[selector.index].itemID : nil
            if selectedID != workspace.view?.itemID { execute { try selectWorkspaceView() } }
        }
        return true
    }

    /// Selector commands are shared by keyboard, menu and mouse dispatch. Plain text remains a filter.
    @discardableResult
    private func performViewWorkspaceCommand(_ command: TUICommand?) -> Bool {
        guard viewSelectorVisible, form == nil, picker == nil, columnEditor == nil, panel == nil,
            !isMenuOpen, learning == nil, !isBatchMenuOpen
        else { return false }
        if command == .toggleSelector { viewPreviewFocused = false }
        guard viewWorkspaceFocused else {
            if command == .toggleSelector {
                viewWorkspaceFocused = true
                status = "View selector focused."
                return true
            }
            return false
        }
        guard var selector = viewWorkspace else { return false }
        switch command {
        case .appearance:
            beginAppearance()
            return true
        case .categoryPreferences:
            beginCategoryPreferences()
            return true
        case .moveUp:
            selector.index = max(-1, selector.index - 1)
            viewWorkspace = selector
            execute { try selectWorkspaceView() }
            return true
        case .moveDown:
            selector.index = min(selector.matches.count - 1, selector.index + 1)
            viewWorkspace = selector
            execute { try selectWorkspaceView() }
            return true
        case .first:
            selector.index = -1
            viewWorkspace = selector
            execute { try selectWorkspaceView() }
            return true
        case .last:
            selector.index = max(-1, selector.matches.count - 1)
            viewWorkspace = selector
            execute { try selectWorkspaceView() }
            return true
        case .activate, .focusReport:
            viewWorkspace = selector
            execute { try selectWorkspaceView() }
            viewWorkspaceFocused = false
            return true
        case .newView:
            viewWorkspace = selector
            execute {
                let original = workspace.navigationLocation
                let selectedItemID = current?.itemID
                let selectedRow = itemIndex
                let firstVisibleRow = firstVisibleItem
                let savedColumnOffset = columnOffset
                viewDefinitionDraft = try makeViewDefinitionDraft(
                    original: original, selectedItemID: selectedItemID, selectedRow: selectedRow,
                    firstVisibleRow: firstVisibleRow, columnOffset: savedColumnOffset, isNew: true)
                showViewDefinitionForm()
            }
            return true
        case .editView, .editNote, .properties:
            guard selector.matches.indices.contains(selector.index) else {
                status = "Select a saved view to edit."
                return true
            }
            let selectedID = selector.matches[selector.index].itemID
            let original = workspace.navigationLocation
            let originalSelectedItemID = current?.itemID
            let originalRow = itemIndex
            let originalFirstVisibleRow = firstVisibleItem
            let originalColumnOffset = columnOffset
            viewWorkspace = selector
            execute {
                let selected = try workspace.client.revision(for: selectedID)
                try workspace.openView(selected)
                viewDefinitionDraft = try makeViewDefinitionDraft(
                    original: original, selectedItemID: originalSelectedItemID,
                    selectedRow: originalRow, firstVisibleRow: originalFirstVisibleRow,
                    columnOffset: originalColumnOffset, isNew: false)
                showViewDefinitionForm(focus: command == .editNote ? 1 : command == .properties ? 2 : 0)
            }
            return true
        case .refresh:
            execute {
                try refresh()
                status = "Views refreshed."
            }
            return true
        case .pinView:
            viewWorkspace = selector
            execute { try toggleWorkspacePin() }
            return true
        case .toggleSelector:
            viewPreviewFocused = false
            viewWorkspaceFocused = false
            status = "Items focused. F8 returns to the selector."
            return true
        default: return false
        }
    }

    private func refresh() throws {
        let id = current?.itemID
        if let view = workspace.view {
            try workspace.openView(workspace.client.revision(for: view.itemID))
        } else {
            try workspace.refresh(position: 0)
        }
        itemIndex = id.flatMap { target in workspace.rows.firstIndex { $0.item?.itemID == target } } ?? 0
        if viewWorkspace != nil { try reloadViewWorkspace() }
    }

    private func columnTarget(_ column: ViewColumn) -> String {
        column.categoryRootID.map { "category:\($0)" } ?? column.property ?? ""
    }

    private func execute(_ action: () throws -> Void) {
        do { try action() } catch { status = String(describing: error) }
    }

    private func makeViewDefinitionDraft(
        original: WorkspaceLocation, selectedItemID: String?, selectedRow: Int, firstVisibleRow: Int,
        columnOffset: Int, isNew: Bool
    ) throws -> ViewDefinitionDraft {
        let categories = try workspace.categories()
        let isCurrentView = !isNew
        return ViewDefinitionDraft(
            original: original, selectedItemID: selectedItemID, selectedRow: selectedRow,
            firstVisibleRow: firstVisibleRow, columnOffset: columnOffset, isNew: isNew,
            form: ViewDefinitionForm(
                name: isCurrentView ? workspace.viewToUpdate?.fields["subject"]?.string ?? "" : "",
                description: isCurrentView ? workspace.viewToUpdate?.fields["body"]?.string ?? "" : "",
                expression: isCurrentView ? workspace.expression : "",
                text: isCurrentView ? workspace.text : "",
                includedCategories: isCurrentView ? workspace.categoryPath : [],
                excludedCategories: isCurrentView
                    ? categories.filter { workspace.excludedCategoryIDs.contains($0.itemID) } : [],
                sections: isCurrentView ? workspace.sectionCategories : [],
                columns: isCurrentView ? workspace.columns : ViewPresentation.defaultColumns,
                sort: isCurrentView ? workspace.sort : [],
                originalSort: isCurrentView
                    ? workspace.viewToUpdate?.fields["viewDefinition"]?.map?["sort"]?.array ?? [] : []))
    }

    private func showViewDefinitionForm(focus: Int = 0) {
        form = Form(purpose: .viewDefinition, title: "View definition", fields: [], labels: [], focus: focus)
        status = "Changes are staged locally. Save writes one guarded revision; Esc discards the draft."
    }

    private func returnToViewDefinitionForm(focus: Int? = nil) {
        guard viewDefinitionDraft != nil else { return }
        showViewDefinitionForm(focus: focus ?? form?.focus ?? 0)
    }

    private func cancelViewDefinition() throws {
        guard let draft = viewDefinitionDraft else { return }
        // Cancellation must always release a local draft.  The prior location can disappear or
        // become unreadable while the modal is open, which is not a reason to trap the user here.
        viewDefinitionDraft = nil
        form = nil
        picker = nil
        columnEditor = nil
        do {
            _ = try workspace.restore(draft.original)
        } catch {
            workspace.clearResults()
            itemIndex = 0
            firstVisibleItem = 0
            columnOffset = 0
            status = "View definition canceled; prior report is unavailable. \(error)"
            return
        }
        let rows = workspace.rows
        itemIndex =
            draft.selectedItemID.flatMap { id in rows.firstIndex { $0.item?.itemID == id } }
            ?? min(draft.selectedRow, max(0, rows.count - 1))
        firstVisibleItem = draft.firstVisibleRow
        columnOffset = draft.columnOffset
        status = "View definition canceled; prior report restored."
    }

    private func refreshViewDefinitionDraft() throws {
        // A staged definition queries by its mutable presentation state, while viewToUpdate retains the
        // original readable revision as the only save guard.
        workspace.view = nil
        try workspace.refresh(position: 0)
        itemIndex = 0
        columnOffset = 0
    }

    private func saveViewDefinition(replacing: Bool) throws {
        guard let draft = viewDefinitionDraft else { return }
        guard !draft.form.name.text.isEmpty else {
            throw TractandaError("name", "Enter a view name.")
        }
        let committedSort = try draft.form.committedSort()
        let committedColumns = try draft.form.committedColumns()
        let definition = workspace.makeViewDefinition(
            categoryPath: draft.form.includedCategories,
            excludedCategoryIDs: draft.form.excludedCategories.map(\.itemID),
            expression: draft.form.expression.text, text: draft.form.text.text, sort: committedSort,
            columns: committedColumns, sectionCategories: draft.form.sections,
            collapsedSectionIDs: workspace.collapsedSectionIDs.intersection(
                Set(draft.form.sections.map(\.itemID))),
            sortValues: try draft.form.committedSortValues(), preservingBase: !draft.isNew)
        let request = workspace.viewRequest(
            name: draft.form.name.text, body: draft.form.description.text, replacing: replacing,
            definition: definition)
        if replacing, let base = workspace.viewToUpdate,
            request.changes.allSatisfy({ base.fields[$0.key] == $0.value })
        {
            form = nil
            viewDefinitionDraft = nil
            status = "No changes."
            return
        }
        try queue(request)
    }

    private func handleViewDefinitionForm(_ key: TerminalKey, command: TUICommand?) {
        guard var editing = form, case .viewDefinition = editing.purpose, var draft = viewDefinitionDraft
        else { return }
        var definition = draft.form
        let controls = definition.controls
        guard !controls.isEmpty else { return }
        editing.focus = min(editing.focus, controls.count - 1)
        let control = controls[editing.focus]
        switch command {
        case .cancel:
            execute { try cancelViewDefinition() }
            return
        case .moveUp where !definition.isMultiline(control): editing.focus = max(0, editing.focus - 1)
        case .moveDown where !definition.isMultiline(control):
            editing.focus = min(controls.count - 1, editing.focus + 1)
        case .first where !definition.isText(control): editing.focus = 0
        case .last where !definition.isText(control): editing.focus = controls.count - 1
        case .nextField: editing.focus = (editing.focus + 1) % controls.count
        case .previousField: editing.focus = (editing.focus + controls.count - 1) % controls.count
        case .save:
            execute { try saveViewDefinition(replacing: !viewDefinitionDraft!.isNew) }
            return
        case .saveAs:
            execute { try saveViewDefinition(replacing: false) }
            return
        case .addColumn:
            execute {
                try definition.addColumn()
                draft.form = definition
                viewDefinitionDraft = draft
                form = Form(
                    purpose: .viewDefinition, title: "View definition", fields: [], labels: [],
                    focus: definition.controls.count - 3)
                status = "Column added locally."
            }
            return
        case .deleteColumn:
            guard case .column(let index, _) = control else {
                status = "Focus a column cell to remove that column."
                return
            }
            execute {
                try definition.removeColumn(at: index)
                draft.form = definition
                viewDefinitionDraft = draft
                form = Form(
                    purpose: .viewDefinition, title: "View definition", fields: [], labels: [],
                    focus: min(editing.focus, definition.controls.count - 1))
                status = "Column removed locally."
            }
            return
        case .moveColumnEarlier, .moveColumnLater:
            guard case .column(let index, _) = control else {
                status = "Focus a column cell to reorder its column."
                return
            }
            let newIndex = definition.moveColumn(at: index, forward: command == .moveColumnLater)
            if newIndex != index { editing.focus += (newIndex - index) * 3 }
        case .moveLeft, .moveRight:
            if case .primaryDirection = control {
                definition.cycleDirection(control, forward: command == .moveRight)
            } else if case .secondaryDirection = control {
                definition.cycleDirection(control, forward: command == .moveRight)
            } else if definition.isText(control) {
                definition.edit(
                    control, key: key, command: command, columns: viewFormTextWidth(control),
                    clipboard: clipboard,
                    keymap: keymap)
            }
        case .activate:
            if definition.isMultiline(control) {
                definition.edit(
                    control, key: key, command: nil, columns: viewFormTextWidth(control),
                    clipboard: clipboard,
                    keymap: keymap)
                draft.form = definition
                viewDefinitionDraft = draft
                form = editing
                return
            }
            execute {
                switch control {
                case .includedCategories:
                    try beginPicker(.viewIncludedCategories)
                case .excludedCategories:
                    try beginPicker(.viewExcludedCategories)
                case .sections:
                    try beginPicker(.sections)
                case .primaryDirection, .secondaryDirection:
                    definition.cycleDirection(control, forward: definition.display(control) == "ascending")
                    draft.form = definition
                    viewDefinitionDraft = draft
                default: break
                }
            }
            return
        default:
            if definition.isText(control) {
                definition.edit(
                    control, key: key, command: command, columns: viewFormTextWidth(control),
                    clipboard: clipboard,
                    keymap: keymap)
            }
        }
        draft.form = definition
        viewDefinitionDraft = draft
        form = editing
    }

    private var navigationEntry: NavigationEntry {
        NavigationEntry(
            location: workspace.navigationLocation, selectedItemID: current?.itemID,
            selectedSectionID: currentRow.flatMap { workspace.sections[$0.sectionIndex].category?.itemID },
            selectedRow: itemIndex, firstVisibleRow: firstVisibleItem, columnOffset: columnOffset)
    }

    private func navigate(_ action: () throws -> Void) rethrows {
        let departure = navigationEntry
        try action()
        navigationHistory.recordDeparture(departure, to: workspace.navigationLocation)
    }

    private func restoreNavigation(backward: Bool) throws {
        guard let entry = backward ? navigationHistory.back.last : navigationHistory.forward.last else {
            status = backward ? "No earlier view." : "No later view."
            return
        }
        let departure = navigationEntry
        do {
            let viewChanged = try workspace.restore(entry.location)
            navigationHistory.didRestore(backward: backward, departing: departure)
            let rows = workspace.rows
            let selected = entry.selectedItemID.flatMap { id in
                rows.firstIndex {
                    $0.item?.itemID == id
                        && workspace.sections[$0.sectionIndex].category?.itemID == entry.selectedSectionID
                }
            }
            itemIndex = viewChanged ? 0 : selected ?? min(entry.selectedRow, max(0, rows.count - 1))
            firstVisibleItem = viewChanged ? 0 : entry.firstVisibleRow
            columnOffset = min(entry.columnOffset, max(0, workspace.columns.count - 1))
            status =
                (backward ? "Returned to earlier view" : "Returned to later view")
                + (viewChanged ? " · saved view changed; opened its current definition." : "")
        } catch let error as TractandaError where error.code == "notFound" || error.code == "forbidden" {
            navigationHistory.discardUnavailable(backward: backward)
            itemIndex = 0
            firstVisibleItem = 0
            throw TractandaError(
                error.code,
                "This history entry is unavailable and was removed. Use Back/Forward again or choose another view."
            )
        }
    }

    private var keyContext: KeyContext {
        if columns < 48 || rows < 12 { return .smallScreen }
        // The menu is modal even when opened over a reader or recovery prompt.
        if isMenuOpen { return .menu }
        if pending != nil || pendingBatch != nil || pendingLearning != nil { return .pending }
        if panel != nil { return panel?.title == "Tractanda help" ? .help : .reader }
        if isBatchMenuOpen { return .group }
        if let picker, let form, case .viewDefinition = form.purpose {
            switch picker.purpose {
            case .sections: return .sections
            default: return .picker
            }
        }
        if let form {
            if case .viewDefinition = form.purpose { return .viewDefinition }
            if case .item = form.purpose { return .editor }
            return .form
        }
        if learning != nil { return .learning }
        if let picker {
            switch picker.purpose {
            case .categories:
                return categoryWorkspace?.focus == .right && categoryWorkspace?.rightMode == .category
                    && !categoryPreviewFocused ? .categoryEditor : .categories
            case .sections: return .sections
            case .history: return .history
            default: return .picker
            }
        }
        if columnEditor != nil { return .columns }
        if viewSelectorVisible && viewWorkspaceFocused { return .viewWorkspace }
        return .browser
    }

    func handle(_ key: TerminalKey) {
        if case .mouse(let event) = key {
            handleMouse(event)
            return
        }
        mouse.cancel()
        form?.scrollOffset = nil
        if handlePreviewInput(key) { return }
        if handleViewWorkspace(key) { return }
        let context = keyContext
        dispatch(keymap.command(for: key, in: context), key: key, context: context)
    }

    private var mouseScene: String {
        let context = keyContext
        switch context {
        case .menu:
            if let childMenu { return "children:" + childMenu.id }
            return "menu:" + menuID + ":\(menu?.groupIndex ?? 0)"
        case .form, .editor: return context.rawValue + ":" + (form?.id ?? "")
        case .picker, .categories, .categoryEditor, .sections, .history:
            return context.rawValue + ":" + (picker?.id ?? "")
        case .learning:
            return "learning:" + (learning?.categoryID ?? "") + ":\(learning?.position ?? 0):"
                + (learning?.state?.queryState ?? "") + ":\(String(describing: learning?.mode))"
        case .reader, .help: return context.rawValue + ":\(panel?.text.hashValue ?? 0)"
        default: return context.rawValue + ":" + (workspace.queryState ?? "")
        }
    }

    private func browserMouseKey(_ index: Int) -> String? {
        let entries = workspace.rows
        guard entries.indices.contains(index) else { return nil }
        let row = entries[index]
        if let item = row.item { return item.itemID + ":" + item.revisionID }
        let section = workspace.sections[row.sectionIndex]
        let kind: String
        switch row.content {
        case .heading: kind = "heading"
        case .nextPage: kind = "next"
        case .previousPage: kind = "previous"
        case .item: kind = "item"
        }
        return "\(row.sectionIndex):\(kind):\(section.category?.revisionID ?? ""):\(section.position)"
    }

    private func pickerMouseKey(_ index: Int) -> String? {
        guard let picker, picker.matches.indices.contains(index) else { return nil }
        return (picker.tree == nil ? picker.matches[index].itemID : picker.treeRows[index].key)
            + ":" + picker.matches[index].revisionID
    }

    private func viewWorkspaceMouseKey(_ index: Int) -> String? {
        guard let selector = viewWorkspace, selector.matches.indices.contains(index) else { return nil }
        let view = selector.matches[index]
        return view.itemID + ":" + view.revisionID
    }

    private func mouseHit(column: Int, row: Int) -> MouseHit? {
        guard mouseLines.indices.contains(row) else { return nil }
        return mouseLines[row].hits.last { $0.columns.contains(column) }
    }

    private func placeMouseText(_ target: MouseTarget, column: Int, hit: MouseHit, extending: Bool) {
        switch target {
        case .field(let index):
            guard form?.fields.indices.contains(index) == true else { return }
            form?.focus = index
            form?.scrollOffset = nil
        case .fieldText(let index, let offsets):
            guard form?.fields.indices.contains(index) == true, !offsets.isEmpty else { return }
            if form?.focus != index { form?.scrollOffset = nil }
            form?.focus = index
            let position = offsets[max(0, min(offsets.count - 1, column - hit.columns.lowerBound))]
            form?.fields[index].placeCursor(at: position, extendingSelection: extending)
        case .viewDefinitionText(let index, let offsets):
            guard var draft = viewDefinitionDraft, draft.form.controls.indices.contains(index),
                !offsets.isEmpty
            else { return }
            form?.focus = index
            let position = offsets[max(0, min(offsets.count - 1, column - hit.columns.lowerBound))]
            draft.form.placeCursor(draft.form.controls[index], at: position, extending: extending)
            viewDefinitionDraft = draft
        case .pickerText(let offsets):
            if activeWorkspace == .categories {
                categoryPreviewFocused = false
                if picker?.purpose == .categories { categoryWorkspace?.focus = .navigator }
            }
            guard !offsets.isEmpty else { return }
            picker?.filter.placeCursor(
                at: offsets[max(0, min(offsets.count - 1, column - hit.columns.lowerBound))],
                extendingSelection: extending)
        case .viewWorkspaceText(let offsets):
            viewPreviewFocused = false
            guard !offsets.isEmpty else { return }
            viewWorkspaceFocused = true
            viewWorkspace?.filter.placeCursor(
                at: offsets[max(0, min(offsets.count - 1, column - hit.columns.lowerBound))],
                extendingSelection: extending)
        case .categoryInspectorText(let index, let offsets):
            guard var manager = categoryWorkspace, var inspector = manager.inspector, !offsets.isEmpty else {
                return
            }
            inspector.focus = index
            inspector.fields[index].placeCursor(
                at: offsets[max(0, min(offsets.count - 1, column - hit.columns.lowerBound))],
                extendingSelection: extending)
            manager.inspector = inspector
            manager.focus = .right
            categoryWorkspace = manager
        case .viewDefinitionControl(let index):
            guard viewDefinitionDraft?.form.controls.indices.contains(index) == true else { return }
            form?.focus = index
        default: break
        }
    }

    private func dragMouseText(_ press: MouseGesture.Press, event: TerminalMouseEvent) {
        let field: Int
        switch press.target {
        case .fieldText(let index, _), .viewDefinitionText(let index, _),
            .categoryInspectorText(let index, _):
            field = index
        case .pickerText: field = -1
        case .viewWorkspaceText: field = -2
        default: return
        }
        var candidates: [(row: Int, hit: MouseHit)] = []
        for (row, line) in mouseLines.enumerated() {
            for hit in line.hits {
                switch hit.target {
                case .fieldText(let index, _) where index == field: candidates.append((row, hit))
                case .viewDefinitionText(let index, _) where index == field: candidates.append((row, hit))
                case .categoryInspectorText(let index, _) where index == field: candidates.append((row, hit))
                case .pickerText where field == -1: candidates.append((row, hit))
                case .viewWorkspaceText where field == -2: candidates.append((row, hit))
                default: break
                }
            }
        }
        guard let nearest = candidates.min(by: { abs($0.row - event.row) < abs($1.row - event.row) }) else {
            return
        }
        let column =
            event.row < nearest.row
            ? nearest.hit.columns.lowerBound
            : event.row > nearest.row ? nearest.hit.columns.upperBound : event.column
        placeMouseText(nearest.hit.target, column: column, hit: nearest.hit, extending: true)
    }

    func handleMouse(
        _ event: TerminalMouseEvent, at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard isMouseEnabled, columns >= 48, rows >= 12, keyContext != .pending,
            mouseFrameScene == mouseScene, mouseFrameSize.columns == columns, mouseFrameSize.rows == rows,
            event.column >= 0, event.column < columns - 1, event.row >= 0, event.row < rows
        else {
            mouse.cancel()
            return
        }
        let scene = mouseScene
        switch event.kind {
        case .hover:
            mouse.cancel()
            hoverMenu(column: event.column, row: event.row)
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            mouse.cancel()
            scrollMouse(event)
        case .press:
            guard event.button == .left else {
                mouse.cancel()
                return
            }
            guard let hit = mouseHit(column: event.column, row: event.row) else {
                mouse.press =
                    isMenuOpen
                    ? .init(target: .menuSurface, scene: scene, column: event.column, row: event.row) : nil
                mouse.lastClick = nil
                return
            }
            mouse.press = .init(target: hit.target, scene: scene, column: event.column, row: event.row)
            placeMouseText(
                hit.target, column: event.column, hit: hit, extending: event.modifiers.contains(.shift))
        case .drag:
            guard event.button == .left, let press = mouse.press, press.scene == scene else { return }
            mouse.press?.dragged = true
            mouse.lastClick = nil
            if press.target == .categoryDivider, var manager = categoryWorkspace, columns >= 80 {
                manager.splitWidth = min(
                    0.70, max(0.20, Double(event.column) / Double(max(1, columns - 1))))
                categoryWorkspace = manager
            } else if press.target == .viewDivider, columns >= 80 {
                viewPreferences.selectorSplitWidth = min(
                    0.70, max(0.20, Double(event.column) / Double(max(1, columns - 1))))
            } else if press.target == .previewDivider, isBottomPreviewVisible {
                resizeItemPreview(toPointerRow: event.row)
            } else if keyContext == .menu {
                hoverMenu(column: event.column, row: event.row)
            } else {
                dragMouseText(press, event: event)
            }
        case .release:
            guard event.button == .left || event.button == .none, let press = mouse.press,
                press.scene == scene
            else { return }
            mouse.press = nil
            switch press.target {
            case .fieldText, .viewDefinitionText, .pickerText, .viewWorkspaceText, .categoryInspectorText:
                if press.dragged || press.column != event.column || press.row != event.row {
                    dragMouseText(press, event: event)
                }
                mouse.lastClick = nil
                return
            case .field:
                mouse.lastClick = nil
                return
            default: break
            }
            if press.target == .categoryDivider {
                saveCategoryWorkspacePreferences()
                mouse.lastClick = nil
                return
            }
            if press.target == .viewDivider {
                do { try viewPreferences.save(to: viewPreferencesURL) } catch {
                    status = "Could not save selector width: \(error)"
                }
                mouse.lastClick = nil
                return
            }
            if press.target == .previewDivider {
                mouse.lastClick = nil
                if press.dragged { savePreviewDrag() }
                if !press.dragged {
                    activateMouse(.itemPreview, modifiers: event.modifiers, scene: scene, time: time)
                }
                return
            }
            guard !press.dragged else { return }
            let hit = mouseHit(column: event.column, row: event.row)
            if press.target == .menuSurface {
                if hit == nil {
                    menu = nil
                    childMenu = nil
                }
                mouse.lastClick = nil
                return
            }
            guard hit?.target == press.target else {
                mouse.lastClick = nil
                return
            }
            activateMouse(press.target, modifiers: event.modifiers, scene: scene, time: time)
        }
    }

    /// Pointer motion selects only visible, enabled menu entries; it never dispatches a command.
    private func hoverMenu(column: Int, row: Int) {
        if var children = childMenu {
            guard let hit = mouseHit(column: column, row: row),
                case .childCategory(let index, let id) = hit.target,
                children.children.indices.contains(index), children.children[index].itemID == id
            else { return }
            children.index = index
            childMenu = children
            return
        }
        guard keyContext == .menu, var selection = menu,
            let hit = mouseHit(column: column, row: row)
        else { return }
        switch hit.target {
        case .menuGroup(let index):
            guard selection.groups.indices.contains(index), index != selection.groupIndex,
                !selection.groups[index].commands.isEmpty
            else { return }
            selection.groupIndex = index
            selection.firstVisibleRow = 0
            selection.selectBoundary(last: false, isEnabled: isMenuCommandEnabled)
        case .menuCommand(let command):
            guard isMenuCommandEnabled(command), let index = selection.group.commands.firstIndex(of: command)
            else { return }
            selection.commandIndex = index
        default: return
        }
        menu = selection
    }

    private func activateMouse(
        _ target: MouseTarget, modifiers: KeyModifiers, scene: String, time: TimeInterval
    ) {
        switch target {
        case .breadcrumb(let index, let path):
            mouse.lastClick = nil
            execute { try openBreadcrumb(at: index, expectedPath: path) }
        case .breadcrumbChooser(let path):
            mouse.lastClick = nil
            guard workspace.categoryPath.map(\.itemID) == path else { return }
            picker = Picker(purpose: .breadcrumb, source: workspace.categoryPath, base: nil)
        case .breadcrumbChildren(let index, let path):
            mouse.lastClick = nil
            let anchor =
                mouseLines.indices.contains(1)
                ? mouseLines[1].hits.first(where: { $0.target == target })?.columns.lowerBound ?? 1 : 1
            execute { try openChildCategories(at: index, expectedPath: path, anchor: anchor) }
        case .categoryBreadcrumb(let index, let path):
            mouse.lastClick = nil
            selectCategoryWorkspacePath(ids: Array(path.prefix(index + 1)))
        case .categoryBreadcrumbChooser(let path):
            mouse.lastClick = nil
            guard categoryWorkspace?.selectedPath.map(\.itemID) == path else { return }
            categoryBreadcrumbReturnPicker = picker
            picker = Picker(purpose: .breadcrumb, source: categoryWorkspace?.selectedPath ?? [], base: nil)
        case .categoryBreadcrumbChildren(let index, let path):
            mouse.lastClick = nil
            let anchor =
                mouseLines.enumerated().compactMap { row, line in
                    line.hits.first(where: { $0.target == target }).map { (row, $0.columns.lowerBound) }
                }.first?.1 ?? 1
            execute { try openCategoryChildMenu(at: index, expectedPath: path, anchor: anchor) }
        case .childCategory(let index, let id):
            guard let children = childMenu, children.children.indices.contains(index),
                children.children[index].itemID == id
            else { return }
            mouse.lastClick = nil
            childMenu?.index = index
            handleChildMenu(.activate, key: .ignored)
        case .browserRow(let index, let key), .browserMark(let index, let key),
            .browserDisclosure(let index, let key):
            viewPreviewFocused = false
            guard browserMouseKey(index) == key else {
                mouse.cancel()
                return
            }
            itemIndex = index
            if target == .browserMark(index, key) || modifiers.contains(.control) {
                mouse.lastClick = nil
                execute { try toggleMark() }
            } else if target == .browserDisclosure(index, key) {
                mouse.lastClick = nil
                execute { try collapseSection() }
            } else if mouse.isDoubleClick(target, scene: scene, at: time) {
                dispatch(.activate, context: .browser)
            } else if let row = currentRow {
                switch row.content {
                case .nextPage, .previousPage:
                    mouse.lastClick = nil
                    execute { try activateRow() }
                default: break
                }
            }
        case .pickerRow(let index, let key), .pickerDisclosure(let index, let key),
            .pickerToggle(let index, let key):
            if activeWorkspace == .categories { categoryPreviewFocused = false }
            guard pickerMouseKey(index) == key else {
                mouse.cancel()
                return
            }
            if picker?.purpose == .categories, let path = picker?.treeRows[index].path {
                if categoryWorkspace?.hasDirtyInspector == true {
                    _ = guardCategoryDraft(for: .select(path))
                    return
                }
                picker?.index = index
                selectCategoryWorkspacePath(path)
            } else {
                picker?.index = index
            }
            if target == .pickerDisclosure(index, key) {
                mouse.lastClick = nil
                picker?.toggleBranch(at: index)
            } else if target == .pickerToggle(index, key) {
                mouse.lastClick = nil
                handlePicker(.ignored, command: .toggle)
            } else if mouse.isDoubleClick(target, scene: scene, at: time) {
                handlePicker(.ignored, command: .activate)
            }
        case .categoryAllItems:
            categoryPreviewFocused = false
            _ = guardCategoryDraft(for: .select([]))
        case .categoryModeItems:
            categoryPreviewFocused = false
            categoryWorkspace?.rightMode = .items
            categoryWorkspace?.focus = .right
            saveCategoryWorkspacePreferences()
        case .categoryModeInspector:
            categoryPreviewFocused = false
            execute { try beginCategoryInspector() }
        case .categoryPreviewPrevious:
            if let manager = categoryWorkspace, manager.preview.position > 0 {
                requestCategoryPreview(
                    path: manager.selectedPath, position: max(0, manager.preview.position - 64))
            }
        case .categoryPreviewNext:
            if let manager = categoryWorkspace,
                manager.preview.position + manager.preview.rows.count < manager.preview.total
            {
                requestCategoryPreview(path: manager.selectedPath, position: manager.preview.position + 64)
            }
        case .categoryDirtyDiscard:
            let action = categoryDirtyAction
            categoryWorkspace?.inspector = nil
            categoryDirtyAction = nil
            form = nil
            if let action { performCategoryDirtyAction(action) }
            status = "Draft canceled; no edit was submitted."
        case .categoryPreviewRow(let index, let key):
            categoryPreviewFocused = false
            guard var manager = categoryWorkspace, manager.preview.rows.indices.contains(index),
                manager.preview.rows[index].itemID == key
            else { return }
            manager.previewIndex = index
            manager.focus = .right
            categoryWorkspace = manager
            if mouse.isDoubleClick(target, scene: scene, at: time) { show(manager.preview.rows[index]) }
        case .itemPreview:
            mouse.lastClick = nil
            if activeWorkspace == .categories {
                categoryPreviewFocused = true
                categoryWorkspace?.focus = .right
            } else {
                viewPreviewFocused = true
                viewWorkspaceFocused = false
            }
        case .previewDivider:
            // Release is handled as either a resize or a harmless focus click above.
            break
        case .categoryToggleTree:
            categoryWorkspace?.connectedTree.toggle()
            saveCategoryWorkspacePreferences()
        case .categoryToggleMaximize:
            categoryWorkspace?.isMaximized.toggle()
        case .viewWorkspaceRow(let index, let key):
            viewPreviewFocused = false
            guard viewWorkspaceMouseKey(index) == key else { return }
            viewWorkspace?.index = index
            viewWorkspaceFocused = true
            execute { try selectWorkspaceView() }
            if mouse.isDoubleClick(target, scene: scene, at: time) {
                viewWorkspaceFocused = false
            }
        case .viewWorkspaceAllItems:
            viewPreviewFocused = false
            viewWorkspace?.index = -1
            viewWorkspaceFocused = true
            execute { try selectWorkspaceView() }
            if mouse.isDoubleClick(target, scene: scene, at: time) {
                viewWorkspaceFocused = false
            }
        case .viewDefinitionControl(let index):
            guard viewDefinitionDraft?.form.controls.indices.contains(index) == true else { return }
            form?.focus = index
            if mouse.isDoubleClick(target, scene: scene, at: time) {
                handleViewDefinitionForm(.enter, command: .activate)
            }
        case .learningRow(let index, let key):
            guard let learning, learning.rows.indices.contains(index),
                learning.rows[index].item.itemID + ":" + learning.rows[index].item.revisionID == key
            else { return }
            learning.index = index
            if mouse.isDoubleClick(target, scene: scene, at: time) { handleLearning(.activate) }
        case .columnRow(let index, let property):
            guard columnEditor?.columns.indices.contains(index) == true,
                columnTarget(columnEditor!.columns[index]) == property
            else { return }
            columnEditor?.index = index
            if mouse.isDoubleClick(target, scene: scene, at: time) { handleColumns(.editColumn) }
        case .menuGroup(let index):
            guard var selection = menu, selection.groups.indices.contains(index),
                !selection.groups[index].commands.isEmpty
            else { return }
            mouse.lastClick = nil
            selection.groupIndex = index
            selection.firstVisibleRow = 0
            selection.selectBoundary(last: false, isEnabled: isMenuCommandEnabled)
            menu = selection
        case .menuCommand(let command):
            guard menu?.group.commands.contains(command) == true, isMenuCommandEnabled(command) else {
                return
            }
            mouse.lastClick = nil
            menu = nil
            dispatch(command, context: menuContext)
        case .menuStep(let direction):
            mouse.lastClick = nil
            handleMenu(direction < 0 ? .moveLeft : .moveRight, key: .ignored)
        case .function(let number):
            mouse.lastClick = nil
            if number == 5 || number == 6, let form, case .appearance = form.purpose {
                handleForm(.function(number), command: nil)
            } else {
                dispatch(
                    keymap.command(for: .function(number), in: keyContext), key: .function(number),
                    context: keyContext)
            }
        case .command(let command):
            mouse.lastClick = nil
            if keyContext == .viewWorkspace {
                _ = performViewWorkspaceCommand(command)
            } else if command == .saveAs || command == .deleteAppearancePreset, let form,
                case .appearance = form.purpose
            {
                handleForm(.ignored, command: command)
            } else {
                dispatch(command, context: keyContext)
            }
        default: mouse.lastClick = nil
        }
    }

    private func scrollMouse(_ event: TerminalMouseEvent) {
        if isMainWorkspaceInput, isBottomPreviewVisible,
            mouseHit(column: event.column, row: event.row)?.target == .itemPreview
        {
            activePreviewFocused = true
            if event.kind == .scrollUp || event.kind == .scrollDown {
                scrollItemPreview(by: event.kind == .scrollDown ? 3 : -3)
            }
            return
        }
        if viewSelectorVisible, let hit = mouseHit(column: event.column, row: event.row),
            case .viewWorkspaceRow = hit.target
        {
            viewWorkspaceFocused = true
            _ = handleViewWorkspace(event.kind == .scrollDown ? .down : .up)
            return
        }
        let context = keyContext
        if event.kind == .scrollLeft || event.kind == .scrollRight {
            if context == .browser {
                dispatch(event.kind == .scrollLeft ? .previousColumn : .nextColumn, context: context)
            }
            return
        }
        let forward = event.kind == .scrollDown
        if context == .form || context == .editor {
            if let viewport = editorViewport, viewport.field == form?.focus {
                let offset = form?.scrollOffset ?? viewport.offset
                form?.scrollOffset = max(0, min(viewport.maximum, offset + (forward ? 3 : -3)))
            }
            return
        }
        if context == .categories || context == .categoryEditor, var manager = categoryWorkspace,
            manager.focus == .right,
            manager.rightMode == .category,
            let viewport = categoryInspectorViewport, manager.inspector?.focus == viewport.field
        {
            manager.inspectorScroll = max(
                0,
                min(
                    viewport.maximum,
                    (manager.inspectorScroll ?? viewport.start) + (event.kind == .scrollDown ? 3 : -3)))
            categoryWorkspace = manager
            return
        }
        for _ in 0..<3 {
            if context == .learning, let learning {
                if (forward && learning.index == learning.rows.count - 1 && learning.hasNextPage)
                    || (!forward && learning.index == 0 && learning.position > 0)
                {
                    execute {
                        try learning.loadPage(forward: forward)
                        if !forward { learning.index = max(0, learning.rows.count - 1) }
                    }
                    continue
                }
            }
            if context == .browser, let row = currentRow {
                if case .nextPage = row.content, forward {
                    execute { try activateRow() }
                    continue
                }
                if case .previousPage = row.content, !forward {
                    execute { try activateRow() }
                    continue
                }
            }
            dispatch(forward ? .moveDown : .moveUp, context: context)
        }
    }

    private func dispatch(_ command: TUICommand?, key: TerminalKey = .ignored, context: KeyContext) {
        if command == .toggleSelector, context == .browser, activeWorkspace == .views {
            viewPreviewFocused = false
            viewSelectorVisible = true
            viewWorkspaceFocused = true
            if viewWorkspace == nil { execute { try reloadViewWorkspace() } }
            status = "View selector focused."
            return
        }
        // A menu remembers the context in which it opened.  Selector commands used to reach this
        // method from F10, but only the keyboard path called the selector's shared handler.
        // Keep mouse and menu activation on exactly the same command route as direct keys.
        if context == .viewWorkspace, performViewWorkspaceCommand(command) { return }
        if command == .quit {
            isRunning = false
            return
        }
        if command == .commands {
            childMenu = nil
            menuContext = context
            var selection = CommandMenu(keymap: keymap, context: context)
            selection.selectBoundary(last: false, isEnabled: isMenuCommandEnabled)
            menu = selection
            menuID = Identifier.make()
            return
        }
        if command == .about {
            let identity = RuntimeIdentity.current
            panel = (
                "About Tractanda",
                "Tractanda terminal client\nVersion: \(identity.version)\n\n"
                    + "Shared knowledge, connected through categories and views.\n\n"
                    + "https://tractanda.ai\n\nEsc or F9 closes this panel."
            )
            panelOffset = 0
            return
        }
        // These actions are global. In particular Appearance suspends a draft instead of replacing
        // it, so opening Preferences from a menu cannot discard an item or category edit.
        if command == .appearance || command == .categoryPreferences {
            guard !(form?.purpose.isSettings ?? false) else { return }
            if command == .appearance {
                beginAppearance()
            } else {
                beginCategoryPreferences()
            }
            return
        }
        switch command {
        case .switchWorkspace: switchWorkspace()
        case .workspaceViews: switchWorkspace(to: .views)
        case .workspaceCategories: switchWorkspace(to: .categories)
        case .togglePreview: toggleItemPreview()
        case .growPreview: resizeItemPreview(by: 1)
        case .shrinkPreview: resizeItemPreview(by: -1)
        case .resetPreview: resizeItemPreview(reset: true)
        default: break
        }
        if command == .switchWorkspace || command == .workspaceViews || command == .workspaceCategories
            || command == .togglePreview || command == .growPreview || command == .shrinkPreview
            || command == .resetPreview
        {
            return
        }
        if context == .smallScreen { return }
        if context == .pending {
            switch command {
            case .retry:
                if pendingLearning != nil {
                    sendPendingLearning()
                } else if pendingBatch != nil {
                    sendPendingBatch()
                } else {
                    sendPending()
                }
            case .help:
                panel = (
                    "Unconfirmed operation",
                    "R resumes the exact saved requests and revision guards. Confirmed results are retained. Q quits while preserving recovery. On next launch, choose R to resume.\n\n"
                        + journal.url.path
                )
            case .cancel: panel = nil
            default: break
            }
            return
        }
        if command == .help {
            showHelp(context: context == .menu ? menuContext : context)
            return
        }
        switch command {
        case .mouseOn, .mouseOff:
            isMouseEnabled = command == .mouseOn
            mouse.cancel()
            return
        case .functionKeysAutomatic:
            functionKeys = .automatic
            return
        case .functionKeysTen:
            functionKeys = .ten
            return
        case .functionKeysTwelve:
            functionKeys = .twelve
            return
        default: break
        }
        switch context {
        case .reader, .help:
            switch command {
            case .cancel:
                panel = nil
                panelOffset = 0
            case .moveDown: panelOffset += 1
            case .moveUp: panelOffset = max(0, panelOffset - 1)
            case .pageDown: panelOffset += max(1, rows - 6)
            case .pageUp: panelOffset = max(0, panelOffset - max(1, rows - 6))
            case .first: panelOffset = 0
            case .last: panelOffset = Int.max / 2
            default: break
            }
        case .menu: handleMenu(command, key: key)
        case .learning: handleLearning(command)
        case .group: handleBatchMenu(command)
        case .editor, .form: handleForm(key, command: command)
        case .viewDefinition: handleViewDefinitionForm(key, command: command)
        case .categories, .categoryEditor, .picker, .sections, .history: handlePicker(key, command: command)
        case .columns: handleColumns(command)
        case .browser:
            switch command {
            case .moveUp: itemIndex = max(0, itemIndex - 1)
            case .moveDown: itemIndex = min(max(0, workspace.rows.count - 1), itemIndex + 1)
            case .first: itemIndex = 0
            case .last: itemIndex = max(0, workspace.rows.count - 1)
            case .pageDown:
                if case .nextPage = currentRow?.content {
                    execute { try activateRow() }
                } else {
                    itemIndex = min(max(0, workspace.rows.count - 1), itemIndex + reportPageHeight)
                }
            case .pageUp:
                if case .previousPage = currentRow?.content {
                    execute { try activateRow() }
                } else {
                    itemIndex = max(0, itemIndex - reportPageHeight)
                }
            case .moveLeft: execute { try collapseSection(true) }
            case .moveRight: execute { try collapseSection(false) }
            case .toggle: execute { try collapseSection() }
            case .previousColumn: columnOffset = max(0, columnOffset - 1)
            case .nextColumn: columnOffset = min(workspace.columns.count - 1, columnOffset + 1)
            case .parent:
                execute {
                    try navigate {
                        try workspace.leaveCategory()
                        itemIndex = 0
                    }
                }
            case .activate: execute { try activateRow() }
            case .some(let action): perform(action)
            case .none:
                if case .paste = key {
                    status = "Paste into an editing field. Pasted text does not execute commands."
                }
            }
        default: break
        }
    }

    private func isMenuCommandEnabled(_ command: TUICommand) -> Bool {
        isCommandEnabled(command, in: menuContext)
    }

    private func isCommandEnabled(_ command: TUICommand, in context: KeyContext) -> Bool {
        if isBottomPreviewVisible, activePreviewFocused, context == .browser || context == .categories,
            Self.previewEditingCommands.contains(command)
        {
            return false
        }
        switch command {
        case .about: return true
        case .appearance, .categoryPreferences:
            return !(form?.purpose.isSettings ?? false)
        case .switchWorkspace, .workspaceViews, .workspaceCategories, .togglePreview, .growPreview,
            .shrinkPreview,
            .resetPreview:
            return form == nil && panel == nil && !isBatchMenuOpen && learning == nil
                && (picker == nil || picker?.purpose == .categories)
        default: break
        }
        if context == .browser {
            switch command {
            case .goBack: return !navigationHistory.back.isEmpty
            case .goForward: return !navigationHistory.forward.isEmpty
            case .childCategories:
                return workspace.categoryPath.isEmpty
                    || workspace.categoryPath.last.map {
                        workspace.categoriesWithChildren.contains($0.itemID)
                    } == true
            case .editItem, .editNote, .history, .include, .exclude, .reset, .explain, .done:
                return current != nil
            case .properties:
                return current != nil
                    || currentRow.map { workspace.sections[$0.sectionIndex].category != nil } == true
            case .group, .reviewMarks, .unmarkAll: return !marks.items.isEmpty
            case .selectAll: return workspace.total > 0
            case .deleteItems: return !marks.items.isEmpty || current != nil
            case .mark:
                guard let row = currentRow else { return false }
                if case .heading = row.content { return true }
                return row.item != nil
            default: break
            }
        }
        if context == .viewWorkspace,
            [.editView, .editNote, .properties, .pinView].contains(command)
        {
            guard let selector = viewWorkspace else { return false }
            return selector.matches.indices.contains(selector.index)
        }
        if context == .categories || context == .categoryEditor {
            switch command {
            case .newItem:
                return categoryWorkspace?.focus == .right && categoryWorkspace?.rightMode == .items
            case .include, .exclude, .reset, .explain, .history, .done, .mark:
                guard let manager = categoryWorkspace, manager.focus == .right, manager.rightMode == .items
                else {
                    return false
                }
                return manager.preview.rows.indices.contains(manager.previewIndex)
            case .editItem, .editNote, .properties, .moveCategory, .detachCategory, .deleteCategory,
                .refineCategory, .learning:
                if let manager = categoryWorkspace, manager.focus == .right, manager.rightMode == .items {
                    return manager.preview.rows.indices.contains(manager.previewIndex)
                }
                guard categoryWorkspace?.selectedAllItems == false, let picker else { return false }
                return picker.matches.indices.contains(picker.index)
            default: break
            }
        }
        if context == .learning {
            switch command {
            case .acceptLearning, .rejectLearning, .dismissLearning, .excludeLearning, .clearLearningFeedback:
                return learning?.current != nil
            case .trainLearning, .learningSettings, .resetLearning: return learning?.state != nil
            case .previousResults: return (learning?.position ?? 0) > 0
            case .nextResults: return learning?.hasNextPage == true
            default: break
            }
        }
        if context == .categoryEditor, let inspector = categoryWorkspace?.inspector {
            let field = inspector.fields[inspector.focus]
            switch command {
            case .undo: return field.canUndo
            case .redo: return field.canRedo
            case .copy, .cut: return field.selection != nil && (command == .copy || inspector.focus != 2)
            case .paste: return inspector.focus != 2 && !clipboard.text.isEmpty
            case .selectText, .setMark: return inspector.focus != 2
            default: break
            }
        }
        if let form, form.fields.indices.contains(form.focus), context == .editor || context == .form {
            let field = form.fields[form.focus]
            let isClassField: Bool = {
                if case .item = form.purpose { return form.focus == 2 }
                return false
            }()
            switch command {
            case .undo: return field.canUndo
            case .redo: return field.canRedo
            case .copy, .cut: return field.selection != nil && (command == .copy || !isClassField)
            case .paste: return !isClassField && !clipboard.text.isEmpty
            default: break
            }
        }
        // A stable catalog is not a permissive catalog.  Commands with no concrete route for the
        // preserved context stay visible but are disabled for both keyboard and mouse activation.
        let global: Set<TUICommand> = [
            .help, .quit, .appearance, .categoryPreferences, .mouseOn, .mouseOff, .functionKeysAutomatic,
            .functionKeysTen, .functionKeysTwelve, .switchWorkspace, .workspaceViews,
            .workspaceCategories, .togglePreview,
        ]
        if global.contains(command) { return true }
        let allowed: Set<TUICommand>
        switch context {
        case .browser:
            allowed = [
                .newItem, .editItem, .editNote, .properties, .categories, .views, .filter,
                .sections, .columns, .sort, .include, .exclude, .reset, .explain, .history,
                .refresh, .allItems, .parent, .mark, .unmarkAll, .selectAll, .group,
                .reviewMarks, .done, .deleteItems, .save, .saveAs, .childCategories,
                .goBack, .goForward, .previousResults, .nextResults, .toggleSelector,
            ]
        case .viewWorkspace:
            allowed = [
                .newView, .editView, .editNote, .properties, .pinView, .focusReport, .toggleSelector,
                .refresh,
            ]
        case .categories, .categoryEditor:
            allowed = [
                .newItem, .editItem, .editNote, .properties, .include, .exclude, .reset,
                .explain, .history, .done, .mark, .newChild, .newRoot, .moveCategory,
                .detachCategory, .deleteCategory, .refineCategory, .learning,
                .categoryModeItems, .categoryModeInspector, .categoryToggleTree,
                .categoryToggleMaximize, .refresh, .save, .cancel, .toggleSelector,
            ]
        case .editor, .form:
            allowed = [.save, .cancel, .copy, .cut, .paste, .undo, .redo, .selectText, .setMark]
        case .viewDefinition:
            allowed = [.save, .saveAs, .cancel, .newView, .editView, .filter, .sections, .sort, .columns]
        case .columns:
            allowed = [
                .save, .cancel, .addColumn, .editColumn, .deleteColumn, .moveColumnEarlier, .moveColumnLater,
            ]
        case .reader, .help: allowed = [.cancel]
        case .learning:
            allowed = [
                .learningExamples, .learningSuggestions, .trainLearning, .resetLearning,
                .learningSettings, .acceptLearning, .rejectLearning, .dismissLearning,
                .excludeLearning, .clearLearningFeedback, .previousResults, .nextResults, .refresh, .filter,
                .cancel,
            ]
        case .picker, .sections, .history:
            allowed = [
                .cancel, .save, .newChild, .newRoot, .moveCategory, .detachCategory,
                .deleteCategory, .editItem, .editNote, .properties, .learning, .refineCategory,
            ]
        case .group: allowed = [.cancel, .reviewMarks, .done, .deleteItems]
        case .pending: allowed = [.retry, .cancel]
        case .smallScreen, .text, .menu: allowed = []
        }
        return allowed.contains(command)
    }

    private func handleMenu(_ command: TUICommand?, key: TerminalKey) {
        if childMenu != nil {
            handleChildMenu(command, key: key)
            return
        }
        guard var selection = menu else { return }
        switch command {
        case .cancel:
            menu = nil
            return
        case .moveLeft: selection.moveGroup(-1, isEnabled: isMenuCommandEnabled)
        case .moveRight: selection.moveGroup(1, isEnabled: isMenuCommandEnabled)
        case .moveUp: selection.moveCommand(-1, isEnabled: isMenuCommandEnabled)
        case .moveDown: selection.moveCommand(1, isEnabled: isMenuCommandEnabled)
        case .first: selection.selectBoundary(last: false, isEnabled: isMenuCommandEnabled)
        case .last: selection.selectBoundary(last: true, isEnabled: isMenuCommandEnabled)
        case .pageUp: selection.moveCommand(-max(1, rows - 7), isEnabled: isMenuCommandEnabled)
        case .pageDown: selection.moveCommand(max(1, rows - 7), isEnabled: isMenuCommandEnabled)
        case .activate:
            guard let chosen = selection.command, isMenuCommandEnabled(chosen) else { return }
            menu = nil
            dispatch(chosen, context: menuContext)
            return
        default:
            if let chosen = keymap.command(for: key, in: menuContext), chosen.isMenuAction,
                isMenuCommandEnabled(chosen)
            {
                menu = nil
                dispatch(chosen, context: menuContext)
                return
            }
        }
        menu = selection
    }

    private func menuShortcut(_ command: TUICommand) -> String {
        keymap.preferredKeys(for: command, in: menuContext).first?.label ?? ""
    }

    private func isMenuCommandChecked(_ command: TUICommand) -> Bool {
        switch command {
        case .functionKeysAutomatic: functionKeys == .automatic
        case .functionKeysTen: functionKeys == .ten
        case .functionKeysTwelve: functionKeys == .twelve
        case .mouseOn: isMouseEnabled
        case .mouseOff: !isMouseEnabled
        default: false
        }
    }

    /// Overlay the bar and one dropdown, leaving the underlying view/draft untouched.
    private func overlayMenu(_ selection: CommandMenu, on lines: inout [ScreenLine], width: Int, height: Int)
        -> OverlayRect?
    {
        // The popup owns the whole interaction layer; clicks cannot reach controls behind it.
        for index in 0..<(height - 1) { lines[index].hits = [] }
        let labels = selection.groups.map { " " + $0.title + " " }
        var first = 0
        while first < selection.groupIndex,
            labels[first...selection.groupIndex].reduce(0, { $0 + $1.count }) > width - 4
        { first += 1 }
        var bar: [ScreenSegment] = []
        var used = 0
        var anchor = 0
        var last = first
        var barHits: [MouseHit] = []
        if first > 0 {
            bar.append(ScreenSegment(text: "‹ ", style: .menu))
            barHits.append(MouseHit(columns: 0..<2, target: .menuStep(-1)))
            used = 2
        }
        for index in first..<labels.count {
            guard used + labels[index].count <= width - 2 else { break }
            if index == selection.groupIndex { anchor = used }
            let style: ScreenStyle =
                selection.groups[index].commands.isEmpty
                ? .disabled
                : index == selection.groupIndex ? .menuSelection : .menu
            bar.append(ScreenSegment(text: labels[index], style: style))
            barHits.append(MouseHit(columns: used..<(used + labels[index].count), target: .menuGroup(index)))
            used += labels[index].count
            last = index
        }
        let tail = last < labels.count - 1 ? " ›" : ""
        if !tail.isEmpty { barHits.append(MouseHit(columns: (width - 2)..<width, target: .menuStep(1))) }
        bar.append(
            ScreenSegment(
                text: String(repeating: " ", count: max(0, width - used - tail.count)) + tail, style: .menu))
        lines[1] = ScreenLine(text: bar.map(\.text).joined(), segments: bar, hits: barHits)

        let menuRows = selection.group.rows
        let selectedRow = selection.command.flatMap { menuRows.firstIndex(of: .command($0)) } ?? 0
        let capacity = max(1, height - 6)
        let start = TerminalViewport.start(
            selected: selectedRow, count: menuRows.count, capacity: capacity,
            previous: selection.firstVisibleRow)
        menu?.firstVisibleRow = start
        let visibleRows = Array(menuRows.dropFirst(start).prefix(capacity))
        let maxTitle = selection.group.commands.map { $0.title.count }.max() ?? 20
        let maxShortcut = selection.group.commands.map { menuShortcut($0).count }.max() ?? 0
        let boxWidth = min(width, max(30, min(68, maxTitle + maxShortcut + 9)))
        let x = min(anchor, max(0, width - boxWidth))
        let innerWidth = boxWidth - 2
        let shortcutWidth = min(maxShortcut, max(0, innerWidth / 3))
        func overlay(_ text: String, row: Int, style: ScreenStyle = .menu) {
            lines[row] = ScreenLine.popup(
                text, over: lines[row].text, column: x, boxWidth: boxWidth, width: width, style: style)
        }
        let heading = " " + selection.group.title + (start > 0 ? " ↑ " : " ")
        overlay(
            "┌" + TerminalText.fit(heading, columns: innerWidth).replacingOccurrences(of: " ", with: "─")
                + "┐", row: 2)
        for (offset, row) in visibleRows.enumerated() {
            switch row {
            case .separator: overlay("├" + String(repeating: "─", count: innerWidth) + "┤", row: 3 + offset)
            case .command(let command):
                let enabled = isMenuCommandEnabled(command)
                let marker = command == selection.command && enabled ? ">" : " "
                let checked = isMenuCommandChecked(command) ? "✓" : " "
                let title = TerminalText.fit(command.title, columns: max(0, innerWidth - shortcutWidth - 5))
                let shortcut = TerminalText.fit(menuShortcut(command), columns: shortcutWidth)
                overlay(
                    "│" + marker + checked + " " + title + "  " + shortcut + "│", row: 3 + offset,
                    style: !enabled ? .disabled : command == selection.command ? .menuSelection : .menu)
                if enabled {
                    lines[3 + offset].hits.append(
                        MouseHit(columns: (x + 1)..<(x + boxWidth - 1), target: .menuCommand(command)))
                }
            }
        }
        let remaining = start + visibleRows.count < menuRows.count
        let bottom = remaining ? " ↓ more " : ""
        overlay(
            "└" + TerminalText.fit(bottom, columns: innerWidth).replacingOccurrences(of: " ", with: "─")
                + "┘", row: 3 + visibleRows.count)
        lines[height - 2] = ScreenLine(
            text: " Command menu · ←/→ menus · ↑/↓ choose · Enter select · Esc close")
        return OverlayRect(x: x, y: 2, width: boxWidth, height: visibleRows.count + 2)
    }

    private func collapseSection(_ isCollapsed: Bool? = nil) throws {
        guard let row = currentRow else { return }
        try workspace.toggleSection(row.sectionIndex, isCollapsed: isCollapsed)
        itemIndex = workspace.rows.firstIndex { $0.sectionIndex == row.sectionIndex } ?? 0
    }

    private func overlayChildMenu(
        _ menu: CategoryChildrenMenu, on lines: inout [ScreenLine], width: Int, height: Int
    ) -> OverlayRect? {
        var popup = menu
        let rect = popup.overlay(on: &lines, width: width, height: height)
        childMenu = popup
        return rect
    }

    private func activateRow() throws {
        guard let row = currentRow else { return }
        switch row.content {
        case .item(let item): show(item)
        case .heading: try collapseSection()
        case .previousPage, .nextPage:
            let forward: Bool
            if case .nextPage = row.content { forward = true } else { forward = false }
            try workspace.loadPage(in: row.sectionIndex, forward: forward)
            let indices = workspace.rows.indices.filter {
                workspace.rows[$0].sectionIndex == row.sectionIndex && workspace.rows[$0].item != nil
            }
            itemIndex = (forward ? indices.first : indices.last) ?? 0
        }
    }

    private func toggleMark() throws {
        guard let row = currentRow else { return }
        if let item = row.item {
            try marks.toggle(item)
        } else if case .heading = row.content {
            try marks.toggle(workspace.items(inSectionAt: row.sectionIndex))
        }
        status = "\(marks.items.count) marked · B group operations · Shift-M unmarks all"
    }

    private func handleBatchMenu(_ command: TUICommand?) {
        switch command {
        case .cancel: isBatchMenuOpen = false
        case .reviewMarks:
            panel = (
                "Marked items · \(marks.items.count)",
                marks.items.map { $0.fields["subject"]?.string ?? $0.itemID }.joined(separator: "\n")
            )
            panelOffset = 0
        case .include, .exclude, .reset:
            batchAction = command == .include ? .include : command == .exclude ? .exclude : .reset
            execute {
                try beginPicker(.batchCategory)
                isBatchMenuOpen = false
            }
        case .done, .deleteItems:
            execute {
                if command == .deleteItems {
                    try beginBatch(.delete, items: marks.items)
                } else if let category = try workspace.completionCategory() {
                    try beginBatch(.done, items: marks.items, category: category)
                } else {
                    batchAction = .done
                    try beginPicker(.batchCategory)
                }
                isBatchMenuOpen = false
            }
        default: break
        }
    }

    private func beginBatch(
        _ action: BatchOperation.Action, items: [Revision], category: Revision? = nil
    ) throws {
        let alternatives =
            try action == .done && category != nil ? workspace.completionAlternatives(for: category!) : []
        let operation = try BatchOperation(
            action: action, items: items, category: category, replacingCategories: alternatives)
        form = Form(
            purpose: .batch(operation),
            title: "\(action.title) · \(operation.entries.count) items"
                + (operation.categoryName.map { " · \($0)" } ?? ""),
            fields: [TextBuffer()],
            labels: [action == .delete ? "Type delete; Ctrl-S confirms" : "Type apply; Ctrl-S confirms"])
        status =
            action == .delete
            ? "Deletes every appearance of these items; revision history remains. Esc cancels."
            : "One guarded edit per item. Conflicts are reported individually. Esc cancels."
    }

    private func sendPendingBatch() {
        guard var operation = pendingBatch else { return }
        let categoryOrigin = activeWorkspace == .categories ? categoryWorkspace : nil
        do {
            try journal.save(operation)
            while !operation.isComplete {
                try operation.performNext(using: workspace.client)
                pendingBatch = operation
                // Checkpoint before sending the next item; a replay can only repeat the same intent.
                try journal.save(operation)
            }
            try journal.clear()
            pendingBatch = nil
            form = nil
            picker = nil
            isBatchMenuOpen = false
            for entry in operation.entries where entry.outcome?.status != .rejected {
                marks.remove(entry.itemID)
            }
            var warning = ""
            do {
                try refresh()
                if let categoryOrigin {
                    try beginPicker(.categories)
                    selectCategoryWorkspacePath(ids: categoryOrigin.selectedPath.map(\.itemID))
                    categoryWorkspace?.focus = categoryOrigin.focus
                }
            } catch { warning = "\nRefresh failed: \(error)" }
            panel = ("Group results", operation.report + warning)
            panelOffset = 0
            status = operation.summary + " · rejected items remain marked for review"
        } catch {
            pendingBatch = operation
            status = "Unconfirmed group operation: R resumes exactly; Q keeps recovery. \(error)"
        }
    }

    private func handleColumns(_ command: TUICommand?) {
        guard var editor = columnEditor else { return }
        switch command {
        case .cancel:
            columnEditor = nil
            if viewDefinitionDraft != nil {
                returnToViewDefinitionForm()
                status = "Column changes canceled."
            } else {
                status = "Column changes canceled."
            }
            return
        case .moveUp: editor.index = max(0, editor.index - 1)
        case .moveDown: editor.index = min(editor.columns.count - 1, editor.index + 1)
        case .first: editor.index = 0
        case .last: editor.index = max(0, editor.columns.count - 1)
        case .pageUp: editor.index = max(0, editor.index - max(1, rows - 6))
        case .pageDown: editor.index = min(max(0, editor.columns.count - 1), editor.index + max(1, rows - 6))
        case .moveLeft where editor.index > 0:
            editor.columns.swapAt(editor.index, editor.index - 1)
            editor.index -= 1
        case .moveRight where editor.index + 1 < editor.columns.count:
            editor.columns.swapAt(editor.index, editor.index + 1)
            editor.index += 1
        case .deleteColumn where editor.columns.count > 1:
            editor.columns.remove(at: editor.index)
            editor.index = min(editor.index, editor.columns.count - 1)
        case .save:
            if viewDefinitionDraft != nil {
                workspace.columns = editor.columns
                columnEditor = nil
                execute { try refreshViewDefinitionDraft() }
                returnToViewDefinitionForm()
                status = "Columns staged."
            } else {
                navigate {
                    workspace.columns = editor.columns
                    workspace.view = nil
                    columnOffset = 0
                    columnEditor = nil
                }
                status = "Columns applied locally. S saves; Shift-S saves a new view."
            }
            return
        case .addColumn, .editColumn, .activate:
            let isNew = command == .addColumn
            guard !isNew || editor.columns.count < 8 else {
                status = "A view can display at most eight columns."
                return
            }
            let column = isNew ? nil : editor.columns[editor.index]
            form = Form(
                purpose: .column(isNew ? nil : editor.index),
                title: isNew ? "Add column" : "Edit column",
                fields: [
                    TextBuffer(column.map(columnTarget) ?? ""), TextBuffer(column?.title ?? ""),
                    TextBuffer(String(column?.width ?? 20)),
                ],
                labels: ["Key or category:<UUID>", "Column title", "Preferred width (6–120)"])
        default: break
        }
        columnEditor = editor
    }

    private func perform(_ command: TUICommand) {
        execute {
            switch command {
            case .appearance: beginAppearance()
            case .categoryPreferences: beginCategoryPreferences()
            case .newItem: try beginEdit()
            case .editItem: if let current { try beginEdit(base: current) }
            case .editNote:
                guard let current else { throw TractandaError("selection", "Select an item first.") }
                try beginEdit(base: current)
                form?.focus = 1
            case .properties:
                if let current {
                    try beginEdit(base: current)
                    form?.focus = 2
                } else if let row = currentRow, let category = workspace.sections[row.sectionIndex].category {
                    try beginEdit(base: category)
                    form?.focus = 3
                }
            case .categories: try enterCategoriesWorkspace()
            case .learning: try beginPicker(.learning)
            case .childCategories:
                try openChildCategories(
                    at: workspace.categoryPath.isEmpty ? nil : workspace.categoryPath.count - 1,
                    expectedPath: workspace.categoryPath.map(\.itemID), anchor: 1)
            case .views: try beginPicker(.views)
            case .sections: try beginPicker(.sections)
            case .columns: columnEditor = ColumnEditor(columns: workspace.columns)
            case .sort:
                let order = workspace.sort
                func field(_ index: Int) -> String {
                    guard order.indices.contains(index) else { return "" }
                    return order[index].categoryRootID.map { "category:\($0)" } ?? order[index].property ?? ""
                }
                func direction(_ index: Int) -> String {
                    order.indices.contains(index) && !order[index].isAscending ? "descending" : "ascending"
                }
                form = Form(
                    purpose: .sort(order), title: "Sort items",
                    fields: [
                        TextBuffer(field(0)), TextBuffer(direction(0)), TextBuffer(field(1)),
                        TextBuffer(direction(1)),
                    ],
                    labels: [
                        "Primary target (key or category:<UUID>)", "Primary order",
                        "Secondary target (optional)", "Secondary order",
                    ])
                status =
                    "Default: recently modified first. Set a property and ascending/descending to override."
            case .include: try beginPicker(.include)
            case .exclude: try beginPicker(.exclude)
            case .reset: try beginPicker(.reset)
            case .explain: try beginPicker(.explain)
            case .history: try beginPicker(.history)
            case .filter:
                form = Form(
                    purpose: .filter, title: "Filter items",
                    fields: [TextBuffer(workspace.expression), TextBuffer(workspace.text)],
                    labels: ["Spotlight expression", "Text search"])
            case .save, .saveAs:
                let replacing = command == .save && workspace.viewToUpdate != nil
                form = Form(
                    purpose: .saveView(replacing: replacing),
                    title: replacing ? "Save changes to this view" : "Save view as",
                    fields: [
                        TextBuffer(replacing ? workspace.viewToUpdate?.fields["subject"]?.string ?? "" : ""),
                        TextBuffer(replacing ? workspace.viewToUpdate?.fields["body"]?.string ?? "" : ""),
                    ],
                    labels: ["View name", "Description / note"])
            case .allItems:
                try navigate {
                    try workspace.allItems()
                    itemIndex = 0
                    columnOffset = 0
                }
                status = "All readable items"
            case .goBack: try restoreNavigation(backward: true)
            case .goForward: try restoreNavigation(backward: false)
            case .mark: try toggleMark()
            case .selectAll:
                var selected = marks
                for index in workspace.sections.indices {
                    for item in try workspace.items(inSectionAt: index) where !selected.contains(item.itemID)
                    {
                        try selected.toggle(item)
                    }
                }
                marks = selected
                status = "\(marks.items.count) marked · B group operations · Alt-F7 unmarks all"
            case .deleteItems:
                let items = marks.items.isEmpty ? current.map { [$0] } ?? [] : marks.items
                try beginBatch(.delete, items: items)
            case .unmarkAll:
                marks.clear()
                status = "All items unmarked"
            case .group:
                guard !marks.items.isEmpty else {
                    throw TractandaError(
                        "selection", "F7 or M marks items first; then B opens group operations.")
                }
                isBatchMenuOpen = true
            case .done:
                guard let current else { throw TractandaError("selection", "Select an item first.") }
                if let category = try workspace.completionCategory() {
                    try beginBatch(.done, items: [current], category: category)
                } else {
                    try beginPicker(.completionCategory)
                }
            case .refresh:
                try refresh()
                status = "Refreshed"
            case .help: showHelp(context: .browser)
            case .quit: isRunning = false
            default: break
            }
        }
    }

    private func beginEdit(
        base: Revision? = nil, isCategory: Bool = false, parentID: String? = nil,
        categoryPath: [Revision]? = nil
    ) throws {
        var categories = (categoryPath ?? workspace.categoryPath).map(\.itemID)
        if categoryPath == nil, let row = currentRow,
            let category = workspace.sections[row.sectionIndex].category,
            !categories.contains(category.itemID)
        {
            categories.append(category.itemID)
        }
        var draft = try ItemDraft(
            base: base, categories: isCategory ? [] : categories, isCategory: isCategory)
        draft.parentIDs = parentID.map { [$0] } ?? []
        form = Form(
            purpose: .item(draft),
            title: base == nil ? (isCategory ? "New category" : "New item") : "Edit item",
            fields: [draft.subject, draft.body, draft.className, draft.rule],
            labels: [
                "Subject", "Body / note", "Class (choose with arrows)", "Category rule (blank disables)",
            ])
        status = "Editing an unsaved draft. Ctrl-S saves; Esc cancels."
    }

    private func openBreadcrumb(at index: Int, expectedPath: [String]) throws {
        try navigate {
            try workspace.browse(toCategoryAt: index, expectedPath: expectedPath)
            itemIndex = 0
            firstVisibleItem = 0
        }
        status =
            "Opened breadcrumb · " + (workspace.categoryPath.last?.fields["subject"]?.string ?? "Category")
    }

    private func openChildCategories(at index: Int?, expectedPath: [String], anchor: Int) throws {
        let children = try workspace.childCategories(at: index, expectedPath: expectedPath)
        guard !children.isEmpty else {
            childMenu = nil
            status =
                index == nil
                ? "No readable categories are available." : "This category has no readable child categories."
            return
        }
        let parent = index.flatMap { workspace.categoryNavigation?.items[expectedPath[$0]] }
        menu = nil
        menuContext = .browser
        var popup = CategoryChildrenMenu(
            parentIndex: index, path: expectedPath, parent: parent,
            children: children, anchorColumn: anchor)
        popup.index = children.firstIndex { $0.itemID == popup.activeChildID } ?? 0
        childMenu = popup
    }

    private func selectCategoryWorkspacePath(ids: [String]) {
        guard let choice = picker, choice.purpose == .categories else { return }
        execute {
            // A breadcrumb can lead outside the currently filtered or expanded tree. Revalidate
            // its ancestry against the readable catalog, then reveal that placement explicitly.
            let source = try workspace.categories()
            let tree = try CategoryTree(source, preferredPath: ids)
            var revealed = Picker(purpose: .categories, source: source, base: choice.base, tree: tree)
            revealed.expanded.formUnion(choice.expanded)
            if ids.isEmpty {
                _ = guardCategoryDraft(for: .select([]), proposedPicker: revealed)
            } else if let index = revealed.treeRows.index(ofPath: ids) {
                revealed.index = index
                _ = guardCategoryDraft(
                    for: .select(revealed.treeRows[index].path), proposedPicker: revealed)
            } else {
                status = "That category path is no longer readable."
            }
        }
    }

    private func openCategoryChildMenu(at index: Int?, expectedPath: [String], anchor: Int) throws {
        guard let choice = picker, choice.purpose == .categories else { return }
        let hierarchy = try CategoryHierarchy(workspace.categories())
        let parentID = index.flatMap { expectedPath.indices.contains($0) ? expectedPath[$0] : nil }
        let ids = parentID.map { hierarchy.children[$0] ?? [] } ?? hierarchy.roots
        let children = ids.compactMap { hierarchy.items[$0] }
        guard !children.isEmpty else {
            status =
                parentID == nil
                ? "No readable categories are available." : "This category has no readable child categories."
            return
        }
        let parent = parentID.flatMap { hierarchy.items[$0] }
        var popup = CategoryChildrenMenu(
            parentIndex: index, path: expectedPath, parent: parent, children: children, anchorColumn: anchor)
        popup.index = children.firstIndex { $0.itemID == popup.activeChildID } ?? 0
        childMenu = popup
    }

    private func handleChildMenu(_ command: TUICommand?, key: TerminalKey) {
        guard var popup = childMenu else { return }
        switch command {
        case .cancel, .moveLeft:
            childMenu = nil
            return
        case .moveUp: popup.move(-1)
        case .moveDown: popup.move(1)
        case .first: popup.index = 0
        case .last: popup.index = max(0, popup.children.count - 1)
        case .pageUp: popup.move(-max(1, rows - 7))
        case .pageDown: popup.move(max(1, rows - 7))
        case .activate:
            guard let selected = popup.selected else { return }
            childMenu = nil
            if activeWorkspace == .categories, picker?.purpose == .categories {
                let prefix = popup.parentIndex.map { Array(popup.path.prefix($0 + 1)) } ?? []
                selectCategoryWorkspacePath(ids: prefix + [selected.itemID])
                return
            }
            execute {
                try navigate {
                    try workspace.browse(
                        childID: selected.itemID, at: popup.parentIndex, expectedPath: popup.path)
                    itemIndex = 0
                    firstVisibleItem = 0
                }
                status =
                    "Opened child category · "
                    + (workspace.categoryPath.last?.fields["subject"]?.string ?? "Category")
            }
            return
        default:
            if let action = keymap.command(for: key, in: .browser), action.isMenuAction,
                isMenuCommandEnabled(action)
            {
                childMenu = nil
                dispatch(action, context: .browser)
                return
            }
        }
        childMenu = popup
    }

    private func beginPicker(_ purpose: PickerPurpose, base: Revision? = nil) throws {
        if activeWorkspace == .categories, purpose != .categories, picker?.purpose == .categories {
            categoryToolReturnPicker = picker
        }
        let needsItem = [.include, .exclude, .reset, .explain, .history].contains(purpose)
        let target = base ?? current
        if needsItem && target == nil { throw TractandaError("selection", "Select an item first.") }
        let source: [Revision]
        if purpose == .history {
            source = try workspace.history(of: target!)
        } else if purpose == .views {
            source = try workspace.views()
        } else {
            source = try workspace.categories()
        }
        picker = Picker(
            purpose: purpose, source: source, base: target,
            selected: purpose == .sections && viewDefinitionDraft != nil
                ? viewDefinitionDraft!.form.sections
                : purpose == .sections
                    ? workspace.sectionCategories
                    : purpose == .viewIncludedCategories
                        ? viewDefinitionDraft?.form.includedCategories ?? workspace.categoryPath
                        : purpose == .viewExcludedCategories
                            ? viewDefinitionDraft?.form.excludedCategories
                                ?? source.filter { workspace.excludedCategoryIDs.contains($0.itemID) } : [],
            tree: purpose == .history || purpose == .views
                ? nil : try CategoryTree(source, preferredPath: workspace.categoryPath.map(\.itemID)))
        if let index = picker?.treeRows.index(
            ofPath: (viewDefinitionDraft?.form.includedCategories ?? workspace.categoryPath).map(\.itemID))
        {
            picker?.index = index
        }
        if purpose == .categories {
            var manager = CategoryWorkspace(preferences: viewPreferences)
            let currentIDs = workspace.categoryPath.map(\.itemID)
            if !currentIDs.isEmpty, let index = picker?.treeRows.index(ofPath: currentIDs),
                let row = picker?.treeRows[index]
            {
                picker?.index = index
                manager.selectedAllItems = false
                manager.preview.path = row.path
            }
            categoryWorkspace = manager
            selectCategoryWorkspacePath(manager.preview.path)
        }
    }

    private func saveCategoryWorkspacePreferences() {
        guard let manager = categoryWorkspace else { return }
        viewPreferences.categoryConnectedTree = manager.connectedTree
        viewPreferences.categoryRightMode = manager.rightMode.rawValue
        viewPreferences.categorySplitWidth = manager.splitWidth
        do { try viewPreferences.save(to: viewPreferencesURL) } catch { status = String(describing: error) }
    }

    /// Starts a native, page-bounded category query.  Tests which inject the old in-process
    /// synchronous client use the deterministic seam below; real connections use the typed
    /// Sendable transport and keep the input loop free while a socket is slow.
    private func requestCategoryPreview(
        path: [Revision], position: Int, selection: CategoryPageSelection? = nil
    ) {
        guard var manager = categoryWorkspace else { return }
        categoryPreviewGeneration += 1
        let generation = manager.preview.begin(
            path: path, position: position, generation: categoryPreviewGeneration)
        categoryPageSelection = selection.map { (generation, $0) }
        manager.previewIndex = 0
        manager.previewFirstVisible = 0
        categoryWorkspace = manager
        if let categoryPreviewLoader {
            categoryPreviewLoader.request(
                path: path.map(\.itemID), position: position,
                sort: categoryReportSort.isEmpty
                    ? [try! ItemSort(property: "modifiedAt", isAscending: false)] : categoryReportSort,
                generation: generation)
        } else {
            // ItemClient is intentionally confined to this synchronous test-only path.
            do {
                let page = try CategoryPreviewPage.load(
                    using: workspace.client, path: path.map(\.itemID), position: position,
                    sort: categoryReportSort.isEmpty
                        ? [try ItemSort(property: "modifiedAt", isAscending: false)] : categoryReportSort)
                manager.preview.accept(page, generation: generation)
            } catch { manager.preview.fail(error, generation: generation) }
            categoryWorkspace = manager
            restoreCategoryPageSelection(generation: generation)
        }
    }

    private func restoreCategoryPageSelection(generation: Int) {
        guard let restoration = categoryPageSelection, restoration.generation == generation,
            var manager = categoryWorkspace
        else { return }
        if manager.preview.status == .loaded {
            manager.previewIndex =
                restoration.value.itemID.flatMap { id in manager.preview.rows.firstIndex { $0.itemID == id } }
                ?? min(max(0, restoration.value.index), max(0, manager.preview.rows.count - 1))
            manager.previewFirstVisible = restoration.value.firstVisible
            categoryWorkspace = manager
        }
        categoryPageSelection = nil
    }

    private func collectCategoryPreview() {
        guard let delivery = categoryPreviewLoader?.take(), var manager = categoryWorkspace else { return }
        switch delivery.result {
        case .success(let page): manager.preview.accept(page, generation: delivery.generation)
        case .failure(let message):
            manager.preview.fail(TractandaError("preview", message), generation: delivery.generation)
        }
        categoryWorkspace = manager
        restoreCategoryPageSelection(generation: delivery.generation)
    }

    private func selectCategoryWorkspacePath(
        _ path: [Revision], position: Int = 0, selection: CategoryPageSelection? = nil
    ) {
        guard var manager = categoryWorkspace else { return }
        guard !manager.hasDirtyInspector || manager.inspector?.base.itemID == path.last?.itemID else {
            status = "Save or discard the category draft before changing selection."
            return
        }
        if !manager.hasDirtyInspector, manager.inspector?.base.revisionID != path.last?.revisionID {
            manager.inspector = nil
            manager.inspectorScroll = nil
        }
        manager.selectedAllItems = path.isEmpty
        manager.preview.path = path
        if manager.rightMode == .category, manager.inspector == nil, let selected = path.last {
            do { manager.inspector = try CategoryInspectorDraft(base: selected) } catch {
                status = String(describing: error)
            }
        }
        categoryWorkspace = manager
        requestCategoryPreview(path: path, position: position, selection: selection)
    }

    private func beginCategoryInspector(focus: Int = 0) throws {
        guard var manager = categoryWorkspace else { return }
        manager.rightMode = .category
        manager.focus = .right
        guard !manager.selectedAllItems, let selected = manager.preview.path.last else {
            categoryWorkspace = manager
            saveCategoryWorkspacePreferences()
            status = "All items is an implicit, read-only category choice."
            return
        }
        if manager.inspector == nil { manager.inspector = try CategoryInspectorDraft(base: selected) }
        manager.inspector?.focus = focus
        categoryWorkspace = manager
        saveCategoryWorkspacePreferences()
    }

    private func selectedCategoryItem(_ manager: CategoryWorkspace) -> Revision? {
        guard manager.preview.rows.indices.contains(manager.previewIndex) else { return nil }
        return manager.preview.rows[manager.previewIndex]
    }

    private func markCategoryItem(_ item: Revision) throws {
        var selected = marks
        try selected.toggle(item)
        marks = selected
        status = selected.contains(item.itemID) ? "Item marked." : "Item unmarked."
    }

    private func performCategoryDirtyAction(_ action: CategoryDirtyAction) {
        if let proposed = categoryDirtyPicker, var current = picker {
            // Retain the freshly fetched catalog after Save, applying only presentation intent.
            if current.id == categoryDirtyPickerOriginID {
                current = proposed
            } else {
                current.filter = proposed.filter
                current.expanded = proposed.expanded
            }
            picker = current
        }
        categoryDirtyPicker = nil
        categoryDirtyPickerOriginID = nil
        switch action {
        case .select(let path):
            // A guarded save rebuilds the catalog.  Resolve the path against its current lazy
            // placement rather than carrying stale revision bytes across a rename/move.
            let ids = path.map(\.itemID)
            categoryWorkspace?.focus = .navigator
            if ids.isEmpty {
                categoryWorkspace?.selectedAllItems = true
                selectCategoryWorkspacePath([])
            } else if let index = picker?.treeRows.index(ofPath: ids), let row = picker?.treeRows[index] {
                picker?.index = index
                selectCategoryWorkspacePath(row.path)
            } else {
                status = "Category changed while saving; choose its current placement."
                categoryWorkspace?.selectedAllItems = true
                selectCategoryWorkspacePath([])
            }
        case .close:
            leaveCategoriesWorkspace()
        case .open:
            guard let manager = categoryWorkspace else { return }
            // The selected path already owns the right-hand native report. Return enters that
            // pane; it does not manufacture a third anonymous Items screen or mutate Views.
            categoryWorkspace?.focus = .right
            status = manager.selectedAllItems ? "All items report focused." : "Category item report focused."
        case .refine:
            guard let manager = categoryWorkspace, !manager.selectedAllItems else { return }
            execute {
                try navigate { try workspace.enter(path: manager.selectedPath) }
                leaveCategoriesWorkspace()
                itemIndex = 0
                status = "Added category filter. Backspace removes one; A clears all filters."
            }
        case .command(let command):
            dispatch(command, context: .categories)
        }
    }

    /// A category draft is never silently thrown away.  The compact form uses F8 Save,
    /// F9 Discard and Esc Stay; a guarded save resumes its saved action only on confirmation.
    private func guardCategoryDraft(for action: CategoryDirtyAction, proposedPicker: Picker? = nil) -> Bool {
        categoryDirtyPicker = proposedPicker
        categoryDirtyPickerOriginID = picker?.id
        guard categoryWorkspace?.hasDirtyInspector == true else {
            performCategoryDirtyAction(action)
            return true
        }
        categoryDirtyAction = action
        form = Form(
            purpose: .categoryDirty, title: "Unsaved category draft",
            fields: [TextBuffer()], labels: ["F8 Save · F9 Discard · Esc Stay"])
        form?.focus = 2
        status = "Choose Save, Discard, or Stay. Esc stays with the exact editable draft."
        return true
    }

    private func handleCategoryWorkspace(_ key: TerminalKey, command: TUICommand?) {
        guard var choice = picker, var manager = categoryWorkspace else { return }
        switch command {
        case .switchWorkspace, .workspaceViews:
            leaveCategoriesWorkspace()
            return
        case .workspaceCategories:
            return
        case .togglePreview:
            toggleItemPreview()
            return
        case .growPreview:
            resizeItemPreview(by: 1)
            return
        case .shrinkPreview:
            resizeItemPreview(by: -1)
            return
        case .resetPreview:
            resizeItemPreview(reset: true)
            return
        case .toggleSelector:
            let wasPreviewFocused = categoryPreviewFocused
            categoryPreviewFocused = false
            manager.focus = wasPreviewFocused ? .navigator : manager.focus == .navigator ? .right : .navigator
            categoryWorkspace = manager
            return
        default: break
        }
        let matches = choice.matches
        let selectedPath: [Revision] = manager.selectedAllItems ? [] : manager.preview.path
        if case .tab = key {
            if categoryPreviewFocused {
                categoryPreviewFocused = false
                manager.focus = .navigator
            } else if manager.focus == .navigator {
                manager.focus = .right
                if manager.rightMode == .category { manager.inspector?.focus = 0 }
            } else if manager.rightMode == .category, var inspector = manager.inspector {
                if inspector.focus == inspector.fields.count - 1 {
                    if isBottomPreviewVisible {
                        categoryPreviewFocused = true
                    } else {
                        manager.focus = .navigator
                    }
                } else {
                    inspector.focus += 1
                    manager.inspector = inspector
                    manager.inspectorScroll = nil
                }
            } else if isBottomPreviewVisible {
                categoryPreviewFocused = true
            } else {
                manager.focus = .navigator
            }
            categoryWorkspace = manager
            return
        }
        if case .backTab = key {
            if manager.focus == .navigator {
                if isBottomPreviewVisible {
                    categoryPreviewFocused = true
                } else {
                    manager.focus = .right
                    if manager.rightMode == .category { manager.inspector?.focus = 3 }
                }
            } else if manager.rightMode == .category, var inspector = manager.inspector {
                if inspector.focus == 0 {
                    manager.focus = .navigator
                } else {
                    inspector.focus -= 1
                    manager.inspector = inspector
                    manager.inspectorScroll = nil
                }
            } else {
                manager.focus = .navigator
            }
            categoryWorkspace = manager
            return
        }
        if case .control(5) = key, manager.focus == .navigator {
            execute { try beginCategoryInspector() }
            return
        }
        if case .control(20) = key, manager.focus == .navigator || manager.rightMode == .items {
            manager.connectedTree.toggle()
            categoryWorkspace = manager
            saveCategoryWorkspacePreferences()
            status =
                manager.connectedTree
                ? "Connected tree · Ctrl-T switches to outline."
                : "Outline tree · Ctrl-T switches to connected."
            return
        }
        if manager.focus == .right, manager.rightMode == .category,
            command == .categoryModeInspector || command == .editItem || command == .categoryToggleTree,
            keymap.command(for: key, in: .text) != nil, var inspector = manager.inspector
        {
            inspector.fields[inspector.focus].handle(
                key, multiline: inspector.focus == 1 || inspector.focus == 3,
                columns: categoryInspectorTextWidth, clipboard: clipboard, keymap: keymap)
            manager.inspector = inspector
            manager.inspectorScroll = nil
            categoryWorkspace = manager
            return
        }
        switch command {
        case .toggle:
            manager.rightMode = manager.rightMode == .items ? .category : .items
            manager.focus = .right
            categoryWorkspace = manager
            if manager.rightMode == .category { execute { try beginCategoryInspector() } }
            saveCategoryWorkspacePreferences()
            return
        case .categoryModeItems:
            manager.rightMode = .items
            manager.focus = .right
            categoryWorkspace = manager
            saveCategoryWorkspacePreferences()
            return
        case .categoryModeInspector:
            execute { try beginCategoryInspector() }
            return
        case .categoryToggleTree:
            manager.connectedTree.toggle()
            categoryWorkspace = manager
            saveCategoryWorkspacePreferences()
            return
        case .categoryToggleMaximize:
            manager.isMaximized.toggle()
            categoryWorkspace = manager
            return
        default: break
        }
        if command == .save {
            if manager.rightMode == .items {
                manager.focus = .navigator
                categoryWorkspace = manager
                status = "Category selector focused."
                return
            }
            if var inspector = manager.inspector {
                do {
                    if let request = try inspector.request() {
                        try queue(request)
                    } else {
                        status = "No category changes."
                    }
                } catch { status = String(describing: error) }
            }
            return
        }
        if command == .refresh {
            execute {
                let ids = selectedPath.map(\.itemID)
                let source = try workspace.categories()
                var fresh = Picker(
                    purpose: .categories, source: source, base: choice.base,
                    tree: try CategoryTree(source, preferredPath: ids))
                fresh.expanded.formUnion(choice.expanded)
                fresh.filter = choice.filter
                fresh.index = fresh.treeRows.index(ofPath: ids) ?? 0
                picker = fresh
                requestCategoryPreview(path: selectedPath, position: manager.preview.position)
                status = "Categories refreshed."
            }
            return
        }
        if (command == .editItem || command == .editNote || command == .properties)
            && !(manager.focus == .right && manager.rightMode == .items)
        {
            execute {
                try beginCategoryInspector(focus: command == .editNote ? 1 : command == .properties ? 3 : 0)
            }
            return
        }
        let categoryOperations: Set<TUICommand> = [
            .newChild, .newRoot, .moveCategory, .detachCategory, .deleteCategory, .learning, .refineCategory,
        ]
        if command == .childCategories {
            execute {
                try openCategoryChildMenu(
                    at: manager.selectedAllItems ? nil : manager.selectedPath.count - 1,
                    expectedPath: manager.selectedPath.map(\.itemID), anchor: 1)
            }
            return
        }
        if command == .newItem, manager.focus == .navigator {
            execute {
                try beginEdit(
                    isCategory: true,
                    parentID: manager.selectedAllItems ? nil : manager.selectedPath.last?.itemID)
            }
            return
        }
        if manager.focus == .right, let command, categoryOperations.contains(command),
            !(manager.rightMode == .category && keymap.command(for: key, in: .text) != nil)
        {
            // Menu actions and explicit category shortcuts retain their meaning from either pane.
            // A text binding such as Control-N still belongs to the focused editor.
            manager.focus = .navigator
            categoryWorkspace = manager
            handleCategoryWorkspace(.ignored, command: command)
            return
        }
        if manager.focus == .right {
            if manager.rightMode == .items {
                if command == .newItem {
                    execute { try beginEdit(categoryPath: selectedPath) }
                    return
                }
                if let item = selectedCategoryItem(manager) {
                    switch command {
                    case .editItem:
                        execute { try beginEdit(base: item) }
                        return
                    case .editNote:
                        execute {
                            try beginEdit(base: item)
                            form?.focus = 1
                        }
                        return
                    case .properties:
                        execute {
                            try beginEdit(base: item)
                            form?.focus = 3
                        }
                        return
                    case .include: execute { try beginPicker(.include, base: item) }
                    case .exclude: execute { try beginPicker(.exclude, base: item) }
                    case .reset: execute { try beginPicker(.reset, base: item) }
                    case .explain: execute { try beginPicker(.explain, base: item) }
                    case .history:
                        execute { try beginPicker(.history, base: item) }
                        return
                    case .mark:
                        execute { try markCategoryItem(item) }
                        return
                    case .done:
                        execute {
                            if let category = try workspace.completionCategory() {
                                try beginBatch(.done, items: [item], category: category)
                            } else {
                                try beginPicker(.completionCategory, base: item)
                            }
                        }
                        return
                    default: break
                    }
                }
                switch command {
                case .moveUp:
                    manager.previewIndex = max(0, manager.previewIndex - 1)
                    categoryWorkspace = manager
                case .moveDown:
                    manager.previewIndex = min(
                        max(0, manager.preview.rows.count - 1), manager.previewIndex + 1)
                    categoryWorkspace = manager
                case .first:
                    manager.previewIndex = 0
                    categoryWorkspace = manager
                case .last:
                    manager.previewIndex = max(0, manager.preview.rows.count - 1)
                    categoryWorkspace = manager
                case .activate:
                    if manager.preview.rows.indices.contains(manager.previewIndex) {
                        show(manager.preview.rows[manager.previewIndex])
                    }
                case .pageDown, .nextResults:
                    if manager.preview.position + manager.preview.rows.count < manager.preview.total {
                        categoryWorkspace = manager
                        requestCategoryPreview(path: selectedPath, position: manager.preview.position + 64)
                    }
                case .pageUp, .previousResults:
                    if manager.preview.position > 0 {
                        categoryWorkspace = manager
                        requestCategoryPreview(
                            path: selectedPath, position: max(0, manager.preview.position - 64))
                    }
                case .toggle:
                    manager.rightMode = .category
                    categoryWorkspace = manager
                    execute { try beginCategoryInspector() }
                case .cancel:
                    manager.focus = .navigator
                    categoryWorkspace = manager
                default: break
                }
                return
            }
            if command == .cancel {
                manager.inspector = manager.selectedPath.last.flatMap {
                    try? CategoryInspectorDraft(base: $0)
                }
                manager.inspectorScroll = nil
                manager.focus = .navigator
                status = "Draft canceled; no edit was submitted."
                categoryWorkspace = manager
                return
            }
            if var inspector = manager.inspector {
                if inspector.focus == 2 {
                    let forward: Bool?
                    switch key {
                    case .up, .left: forward = false
                    case .down, .right, .enter: forward = true
                    default: forward = nil
                    }
                    if let forward {
                        do {
                            var draft = try ItemDraft(base: inspector.base)
                            draft.className = inspector.fields[2]
                            draft.cycleClass(forward: forward)
                            inspector.fields[2] = draft.className
                            manager.inspector = inspector
                            categoryWorkspace = manager
                            status = "Class change is staged; Save retypes this category once."
                        } catch { status = String(describing: error) }
                        return
                    }
                    if ![.nextField, .previousField, .editNote, .properties].contains(command) {
                        status = "Choose a supported class with arrows; class names are not free-text fields."
                        return
                    }
                }
                if let command, [.copy, .cut, .paste, .undo, .redo, .selectText, .setMark].contains(command) {
                    inspector.fields[inspector.focus].handle(
                        command: command,
                        multiline: inspector.focus == 1 || inspector.focus == 3,
                        columns: categoryInspectorTextWidth, clipboard: clipboard)
                } else {
                    inspector.fields[inspector.focus].handle(
                        key, multiline: inspector.focus == 1 || inspector.focus == 3,
                        columns: categoryInspectorTextWidth, clipboard: clipboard, keymap: keymap)
                }
                manager.inspectorScroll = nil
                if command == .nextField {
                    inspector.focus = (inspector.focus + 1) % inspector.fields.count
                    manager.inspectorScroll = nil
                }
                if command == .previousField {
                    inspector.focus = (inspector.focus + inspector.fields.count - 1) % inspector.fields.count
                    manager.inspectorScroll = nil
                }
                if command == .editNote {
                    inspector.focus = 1
                    manager.inspectorScroll = nil
                }
                if command == .properties {
                    inspector.focus = 3
                    manager.inspectorScroll = nil
                }
                manager.inspector = inspector
                categoryWorkspace = manager
            }
            return
        }
        switch command {
        case .cancel:
            if guardCategoryDraft(for: .close) { return }
        case .moveDown:
            if manager.selectedAllItems {
                guard !matches.isEmpty else { return }
                choice.index = 0
                if guardCategoryDraft(for: .select(choice.treeRows[0].path), proposedPicker: choice) {
                    return
                }
            } else if choice.index < matches.count - 1 {
                choice.index += 1
                if guardCategoryDraft(
                    for: .select(choice.treeRows[choice.index].path), proposedPicker: choice)
                {
                    return
                }
            }
        case .moveUp:
            if !manager.selectedAllItems, choice.index == 0 {
                if guardCategoryDraft(for: .select([]), proposedPicker: choice) { return }
            } else if !manager.selectedAllItems {
                choice.index -= 1
                if guardCategoryDraft(
                    for: .select(choice.treeRows[choice.index].path), proposedPicker: choice)
                {
                    return
                }
            }
        case .first, .last, .pageUp, .pageDown:
            let position = manager.selectedAllItems ? -1 : choice.index
            let requested: Int
            switch command {
            case .first: requested = -1
            case .last: requested = matches.count - 1
            case .pageUp: requested = position - max(1, rows - 7)
            default: requested = position + max(1, rows - 7)
            }
            let next = min(max(-1, requested), matches.count - 1)
            choice.index = max(0, next)
            let path = next < 0 ? [] : choice.treeRows[next].path
            if guardCategoryDraft(for: .select(path), proposedPicker: choice) { return }
        case .moveLeft where !manager.selectedAllItems:
            let row = choice.treeRows[choice.index]
            if row.isExpanded && choice.filter.text.isEmpty {
                choice.expanded.remove(row.key)
            } else {
                choice.index =
                    choice.treeRows.index(ofPath: row.path.dropLast().map(\.itemID)) ?? choice.index
            }
            if guardCategoryDraft(for: .select(choice.treeRows[choice.index].path), proposedPicker: choice) {
                return
            }
        case .moveRight where !manager.selectedAllItems:
            let row = choice.treeRows[choice.index]
            if row.hasChildren {
                if row.isExpanded && choice.filter.text.isEmpty {
                    choice.index = min(matches.count - 1, choice.index + 1)
                } else {
                    choice.toggleBranch(at: choice.index)
                }
            }
            if guardCategoryDraft(for: .select(choice.treeRows[choice.index].path), proposedPicker: choice) {
                return
            }
        case .editItem: execute { try beginCategoryInspector() }
        case .editNote: execute { try beginCategoryInspector(focus: 1) }
        case .properties: execute { try beginCategoryInspector(focus: 3) }
        case .newChild, .newRoot:
            if manager.hasDirtyInspector {
                _ = guardCategoryDraft(for: .command(command!))
                return
            }
            execute {
                try beginEdit(
                    isCategory: true,
                    parentID: command == .newChild && !manager.selectedAllItems
                        ? selectedPath.last?.itemID : nil)
            }
        case .moveCategory where !manager.selectedAllItems:
            if manager.hasDirtyInspector {
                _ = guardCategoryDraft(for: .command(command!))
                return
            }
            execute { try beginPicker(.parent, base: selectedPath.last) }
        case .detachCategory where !manager.selectedAllItems:
            if manager.hasDirtyInspector {
                _ = guardCategoryDraft(for: .command(command!))
                return
            }
            if let selected = selectedPath.last {
                execute {
                    try queue(
                        CommitRequest(
                            action: .revise, itemID: selected.itemID, expectedRevisionID: selected.revisionID,
                            changes: ["categoryParents": .list([])], operationID: Identifier.make()))
                }
            }
        case .deleteCategory where !manager.selectedAllItems:
            if manager.hasDirtyInspector {
                _ = guardCategoryDraft(for: .command(command!))
                return
            }
            if let selected = selectedPath.last {
                form = Form(
                    purpose: .deleteCategory(selected),
                    title: "Delete category · member items and children are kept",
                    fields: [TextBuffer()], labels: ["Type delete to remove \(choice.title(selected))"])
            }
        case .learning where !manager.selectedAllItems:
            if manager.hasDirtyInspector {
                _ = guardCategoryDraft(for: .command(command!))
                return
            }
            if let selected = selectedPath.last { execute { try beginLearning(categoryID: selected.itemID) } }
        case .toggle:
            manager.rightMode = manager.rightMode == .items ? .category : .items
            manager.focus = .right
            categoryWorkspace = manager
            if manager.rightMode == .category { execute { try beginCategoryInspector() } }
            saveCategoryWorkspacePreferences()
        case .activate:
            if guardCategoryDraft(for: .open) { return }
        case .refineCategory where !manager.selectedAllItems:
            if guardCategoryDraft(for: .refine) { return }
        default:
            let before = choice.filter.text
            choice.filter.handle(key, clipboard: clipboard, keymap: keymap)
            if before != choice.filter.text {
                if before.isEmpty, !choice.filter.text.isEmpty {
                    // Search should keep the currently chosen placement of a shared category.
                    // Rebuild this preference once when search starts, not on every typed letter.
                    do {
                        var searching = Picker(
                            purpose: .categories, source: choice.source, base: choice.base,
                            tree: try CategoryTree(choice.source, preferredPath: selectedPath.map(\.itemID)))
                        searching.expanded.formUnion(choice.expanded)
                        searching.filter = choice.filter
                        choice = searching
                    } catch {
                        status = String(describing: error)
                        return
                    }
                }
                choice.index =
                    choice.treeRows.indices.first {
                        choice.title(choice.treeRows[$0].item).localizedCaseInsensitiveContains(
                            choice.filter.text)
                    } ?? 0
                if choice.filter.text.isEmpty || choice.matches.isEmpty {
                    if guardCategoryDraft(for: .select([]), proposedPicker: choice) { return }
                } else {
                    if guardCategoryDraft(
                        for: .select(choice.treeRows[choice.index].path), proposedPicker: choice)
                    {
                        return
                    }
                }
            }
        }
        // Cancel/activation intentionally clears the category workspace.  Do not resurrect its
        // captured Picker value at the end of this handler.
        if picker?.id == choice.id { picker = choice }
    }

    private func handlePicker(_ key: TerminalKey, command: TUICommand?) {
        guard var choice = picker else { return }
        if choice.purpose == .categories {
            handleCategoryWorkspace(key, command: command)
            return
        }
        let matches = choice.matches
        switch command {
        case .cancel:
            picker = nil
            if choice.purpose == .breadcrumb, let previous = categoryBreadcrumbReturnPicker {
                categoryBreadcrumbReturnPicker = nil
                picker = previous
                return
            }
            if let previous = categoryToolReturnPicker {
                categoryToolReturnPicker = nil
                picker = previous
                return
            }
            if choice.purpose == .sections || choice.purpose.isViewCategoryCriteria {
                returnToViewDefinitionForm()
            }
            return
        case .moveUp: choice.index = max(0, choice.index - 1)
        case .moveDown: choice.index = min(max(0, matches.count - 1), choice.index + 1)
        case .pageUp: choice.index = max(0, choice.index - pageHeight)
        case .pageDown: choice.index = min(max(0, matches.count - 1), choice.index + pageHeight)
        case .first: choice.index = 0
        case .last: choice.index = max(0, matches.count - 1)
        case .moveRight where choice.tree != nil:
            guard choice.treeRows.indices.contains(choice.index) else { return }
            let row = choice.treeRows[choice.index]
            if row.hasChildren {
                if row.isExpanded && choice.filter.text.isEmpty {
                    choice.index = min(matches.count - 1, choice.index + 1)
                } else {
                    choice.toggleBranch(at: choice.index)
                }
            }
        case .moveLeft where choice.tree != nil:
            guard choice.treeRows.indices.contains(choice.index) else { return }
            let row = choice.treeRows[choice.index]
            if row.isExpanded && choice.filter.text.isEmpty {
                choice.expanded.remove(row.key)
            } else {
                choice.index =
                    choice.treeRows.index(ofPath: row.path.dropLast().map(\.itemID)) ?? choice.index
            }
        case .newChild, .newRoot:
            execute {
                try beginEdit(
                    isCategory: true,
                    parentID: command == .newChild && matches.indices.contains(choice.index)
                        ? matches[choice.index].itemID : nil)
            }
            return
        case .moveCategory:
            if matches.indices.contains(choice.index) {
                execute { try beginPicker(.parent, base: matches[choice.index]) }
            }
            return
        case .detachCategory:
            if matches.indices.contains(choice.index) {
                let selected = matches[choice.index]
                execute {
                    try queue(
                        CommitRequest(
                            action: .revise, itemID: selected.itemID,
                            expectedRevisionID: selected.revisionID, changes: ["categoryParents": .list([])],
                            operationID: Identifier.make()))
                }
            }
            return
        case .deleteCategory:
            if matches.indices.contains(choice.index) {
                let selected = matches[choice.index]
                form = Form(
                    purpose: .deleteCategory(selected),
                    title: "Delete category · member items and children are kept",
                    fields: [TextBuffer()], labels: ["Type delete to remove \(choice.title(selected))"])
                picker = nil
            }
            return
        case .editItem, .editNote, .properties:
            if matches.indices.contains(choice.index) {
                execute {
                    try beginEdit(base: matches[choice.index])
                    form?.focus = command == .editNote ? 1 : command == .properties ? 3 : 0
                }
            }
            return
        case .learning:
            if matches.indices.contains(choice.index) {
                execute { try beginLearning(categoryID: matches[choice.index].itemID) }
            }
            return
        case .save where choice.purpose == .sections:
            execute {
                if var draft = viewDefinitionDraft {
                    draft.form.sections = choice.selected
                    viewDefinitionDraft = draft
                    picker = nil
                    returnToViewDefinitionForm(focus: 6)
                    status = "Sections staged."
                    return
                }
                let departure = navigationEntry
                let old = (workspace.sectionCategories, workspace.collapsedSectionIDs, workspace.view)
                workspace.sectionCategories = choice.selected
                workspace.collapsedSectionIDs.formIntersection(Set(choice.selected.map(\.itemID)))
                workspace.view = nil
                do { try workspace.refresh(position: 0) } catch {
                    workspace.sectionCategories = old.0
                    workspace.collapsedSectionIDs = old.1
                    workspace.view = old.2
                    throw error
                }
                picker = nil
                itemIndex = 0
                navigationHistory.recordDeparture(departure, to: workspace.navigationLocation)
                status = "Sections applied locally. S saves; Shift-S saves a new view."
            }
            return
        case .save where choice.purpose.isViewCategoryCriteria:
            execute {
                let selected = choice.selected
                guard var draft = viewDefinitionDraft else { return }
                if choice.purpose == .viewIncludedCategories {
                    draft.form.includedCategories = selected
                } else {
                    draft.form.excludedCategories = selected
                }
                viewDefinitionDraft = draft
                picker = nil
                returnToViewDefinitionForm(focus: choice.purpose == .viewIncludedCategories ? 4 : 5)
                status =
                    choice.purpose == .viewIncludedCategories
                    ? "Included categories staged." : "Excluded categories staged."
            }
            return
        case .activate where choice.purpose == .sections || choice.purpose.isViewCategoryCriteria,
            .toggle where choice.purpose == .sections || choice.purpose.isViewCategoryCriteria:
            guard matches.indices.contains(choice.index) else { return }
            let selected = matches[choice.index]
            if let index = choice.selected.firstIndex(where: { $0.itemID == selected.itemID }) {
                choice.selected.remove(at: index)
            } else if choice.selected.count < (choice.purpose == .sections ? 16 : 32) {
                choice.selected.append(selected)
            } else {
                status =
                    choice.purpose == .sections
                    ? "A view can show at most 16 sections."
                    : "A view can use at most 32 category criteria."
            }
        case .refineCategory:
            guard choice.treeRows.indices.contains(choice.index) else { return }
            execute {
                try navigate {
                    try workspace.enter(path: choice.treeRows[choice.index].path)
                    picker = nil
                    itemIndex = 0
                }
                status = "Added category filter. Backspace removes one; A clears all filters."
            }
            return
        case .activate:
            guard matches.indices.contains(choice.index) else { return }
            let selected = matches[choice.index]
            execute {
                if let previous = categoryToolReturnPicker {
                    categoryToolReturnPicker = nil
                    picker = previous
                }
                switch choice.purpose {
                case .categories:
                    try navigate {
                        try workspace.browse(path: choice.treeRows[choice.index].path)
                        itemIndex = 0
                    }
                    status =
                        "Opened category. A returns to all items; Meta-Return adds a category filter."
                case .learning: try beginLearning(categoryID: selected.itemID)
                case .completionCategory:
                    guard let base = choice.base else { return }
                    try beginBatch(.done, items: [base], category: selected)
                case .breadcrumb:
                    guard let index = choice.source.firstIndex(where: { $0.itemID == selected.itemID }) else {
                        return
                    }
                    if let previous = categoryBreadcrumbReturnPicker {
                        categoryBreadcrumbReturnPicker = nil
                        picker = previous
                        selectCategoryWorkspacePath(ids: choice.source.prefix(index + 1).map(\.itemID))
                        return
                    }
                    try openBreadcrumb(at: index, expectedPath: choice.source.map(\.itemID))
                case .views:
                    try navigate {
                        try workspace.openView(selected)
                        itemIndex = 0
                        columnOffset = 0
                    }
                case .sections, .viewIncludedCategories, .viewExcludedCategories: break
                case .batchCategory:
                    guard let batchAction else {
                        throw TractandaError("selection", "Choose a group operation first.")
                    }
                    try beginBatch(batchAction, items: marks.items, category: selected)
                case .parent:
                    let base = choice.base!
                    try queue(
                        CommitRequest(
                            action: .revise, itemID: base.itemID,
                            expectedRevisionID: base.revisionID,
                            changes: ["categoryParents": .list([.reference(ItemReference(selected.itemID))])],
                            operationID: Identifier.make()))
                case .history: show(selected)
                case .include, .exclude, .reset:
                    let decision =
                        choice.purpose == .include ? "include" : choice.purpose == .exclude ? "exclude" : nil
                    try queue(workspace.assignment(decision, item: choice.base!, category: selected))
                case .explain:
                    let result = try JSON.decode(
                        Membership.self,
                        workspace.client.call(
                            "TractandaItem/explain",
                            arguments: ["itemID": choice.base!.itemID, "categoryID": selected.itemID]))
                    panel = (
                        "Category assignment",
                        "\(choice.base!.fields["subject"]?.string ?? "Item")\n\(selected.fields["subject"]?.string ?? "Category")\n\n\(result.isIncluded ? "Included" : "Excluded"): \(result.reason)"
                    )
                }
                if activeWorkspace != .categories || picker?.purpose != .categories { picker = nil }
            }
            return
        default:
            if choice.purpose != .history {
                let previousFilter = choice.filter.text
                choice.filter.handle(key, clipboard: clipboard, keymap: keymap)
                if previousFilter != choice.filter.text {
                    choice.index =
                        choice.matches.firstIndex {
                            choice.title($0).localizedCaseInsensitiveContains(choice.filter.text)
                        } ?? 0
                    choice.firstVisibleIndex = 0
                }
            }
        }
        picker = choice
    }

    private func handleForm(_ key: TerminalKey, command: TUICommand?) {
        guard var editing = form else { return }
        if case .categoryDirty = editing.purpose {
            switch key {
            case .left, .up, .backTab:
                editing.focus = (editing.focus + 2) % 3
                form = editing
                return
            case .right, .down, .tab:
                editing.focus = (editing.focus + 1) % 3
                form = editing
                return
            case .enter:
                if editing.focus == 0 {
                    handleForm(.ignored, command: .save)
                } else if editing.focus == 1 {
                    handleForm(.function(9), command: .cancel)
                } else {
                    handleForm(.escape, command: .cancel)
                }
                return
            default: break
            }
            guard command == .save || command == .cancel || key == .function(9) else { return }
        }
        if case .categoryPreferences = editing.purpose {
            switch command {
            case .moveUp, .moveDown, .moveLeft, .moveRight, .toggle:
                cycleCategoryNavigator(&editing)
                form = editing
                return
            case .save, .cancel:
                break
            default: break
            }
            if command != .save && command != .cancel {
                switch key {
                case .up, .down, .left, .right, .text(" "):
                    cycleCategoryNavigator(&editing)
                    form = editing
                    return
                default:
                    form = editing
                    status = "Choose Outline or Connected tree with arrows or Space."
                    return
                }
            }
        }
        let originalFieldTexts = editing.fields.map(\.text)
        let textColumns: Int
        if case .item = editing.purpose {
            // The editor is a centered panel rather than the full terminal.  Text motion must
            // wrap at the same width that the mouse and renderer expose.
            textColumns = itemFormTextWidth()
        } else {
            textColumns = max(1, columns - 5)
        }
        let rawDirection: Bool? =
            switch key {
            case .up, .left: false
            case .down, .right: true
            default: nil
            }
        if case .appearance = editing.purpose,
            let forward = rawDirection ?? (command == .moveDown || command == .moveRight ? true : nil)
        {
            cycleAppearanceField(&editing, forward: forward)
            form = editing
            return
        }
        if case .appearance = editing.purpose, case .function(5) = key {
            beginAppearanceName(from: editing)
            return
        }
        if case .appearance = editing.purpose, command == .saveAs {
            beginAppearanceName(from: editing)
            return
        }
        if case .appearance = editing.purpose,
            key == .function(6) || command == .deleteAppearancePreset
        {
            deleteAppearancePreset(&editing)
            return
        }
        if case .appearanceName = editing.purpose {
            handleAppearanceName(&editing, key: key, command: command)
            return
        }
        if case .categoryDirty = editing.purpose, case .function(9) = key {
            let action = categoryDirtyAction
            categoryWorkspace?.inspector = nil
            categoryDirtyAction = nil
            form = nil
            if let action { performCategoryDirtyAction(action) }
            status = "Draft canceled; no edit was submitted."
            return
        }
        if case .item(var draft) = editing.purpose, editing.focus == 2 {
            draft.className = editing.fields[2]
            let forward =
                rawDirection
                ?? (command == .moveDown || command == .moveRight || command == .activate ? true : nil)
            if let forward {
                draft.cycleClass(forward: forward)
                editing.fields[2] = draft.className
                form = editing
                status =
                    draft.isCategory && draft.base == nil
                    ? "New categories use the ordinary Item default."
                    : "Class change is staged; Save retypes this item with its existing identity and history."
                return
            }
            switch command {
            case .save, .cancel, .nextField, .previousField: break
            default:
                status = "Choose a supported class with arrows; class names are not free-text fields."
                return
            }
        }
        switch command {
        case .cancel:
            form = nil
            if case .categoryDirty = editing.purpose {
                categoryDirtyAction = nil
                categoryDirtyPicker = nil
                status = "Stayed with the unsaved category draft."
                return
            }
            if case .appearance(let original) = editing.purpose {
                appearance = original
                returnFromAppearance()
                status = "Appearance changes canceled."
                return
            }
            if case .categoryPreferences(let original) = editing.purpose {
                previewCategoryNavigator(original)
                returnFromCategoryPreferences()
                status = "Category navigator changes canceled."
                return
            }
            let isViewSubeditor: Bool
            switch editing.purpose {
            case .filter, .sort: isViewSubeditor = true
            default: isViewSubeditor = false
            }
            if viewDefinitionDraft != nil, case .column = editing.purpose {
                // Return to the column list first so Esc cancels only this add/edit field.
                status = "Column field canceled. Esc cancels all staged column changes."
            } else if viewDefinitionDraft != nil, isViewSubeditor {
                returnToViewDefinitionForm()
            } else if viewDefinitionDraft != nil {
                execute { try cancelViewDefinition() }
            } else {
                status = "Draft canceled; no edit was submitted."
            }
            return
        case .nextField: editing.focus = (editing.focus + 1) % editing.fields.count
        case .previousField: editing.focus = (editing.focus + editing.fields.count - 1) % editing.fields.count
        case .save:
            execute {
                switch editing.purpose {
                case .appearance:
                    let value = try appearance(from: editing.fields)
                    try value.save(to: appearanceURL)
                    appearance = value
                    returnFromAppearance()
                    status = "Appearance saved locally."
                case .appearanceName:
                    return
                case .categoryPreferences:
                    let connectedTree =
                        editing.fields[0].text.caseInsensitiveCompare("Connected tree") == .orderedSame
                    var saved = viewPreferences
                    saved.categoryConnectedTree = connectedTree
                    try saved.save(to: viewPreferencesURL)
                    viewPreferences = saved
                    previewCategoryNavigator(connectedTree)
                    returnFromCategoryPreferences()
                    status = "Category navigator saved for this profile."
                case .learningSettings(let draft):
                    if let edit = try draft.edit(editing.fields) {
                        try queueLearning(edit)
                    } else {
                        form = nil
                        status = "No learning settings changed."
                    }
                case .learningFilter:
                    guard let learning else { return }
                    try learning.refresh(expression: editing.fields[0].text)
                    form = nil
                    status = "Learning filter applied."
                case .resetLearning(let categoryID):
                    guard editing.fields[0].text == "reset", let learning, learning.categoryID == categoryID
                    else {
                        throw TractandaError(
                            "confirmation", "Type reset to discard this user's learned model only.")
                    }
                    try learning.reset()
                    form = nil
                    status = "Model reset. Assignments, exclusions, feedback and settings are kept."
                case .batch(let operation):
                    let confirmation = operation.action == .delete ? "delete" : "apply"
                    guard editing.fields[0].text == confirmation else {
                        throw TractandaError(
                            "confirmation", "Type \(confirmation) to confirm this group operation.")
                    }
                    try journal.save(operation)
                    pendingBatch = operation
                    sendPendingBatch()
                case .deleteCategory(let category):
                    guard editing.fields[0].text == "delete" else {
                        throw TractandaError(
                            "confirmation",
                            "Type delete to remove this category; its member items will remain.")
                    }
                    try queue(
                        CommitRequest(
                            action: .revise, itemID: category.itemID,
                            expectedRevisionID: category.revisionID, changes: ["isDeleted": .boolean(true)],
                            operationID: Identifier.make()))
                case .categoryDirty:
                    guard let action = categoryDirtyAction,
                        let manager = categoryWorkspace, var inspector = manager.inspector
                    else {
                        form = nil
                        return
                    }
                    if let request = try inspector.request() {
                        categoryWorkspace = manager
                        try queue(request)
                    } else {
                        form = nil
                        categoryDirtyAction = nil
                        performCategoryDirtyAction(action)
                    }
                case .item(var draft):
                    draft.subject = editing.fields[0]
                    draft.body = editing.fields[1]
                    draft.className = editing.fields[2]
                    draft.rule = editing.fields[3]
                    if let request = draft.request() {
                        try queue(request)
                    } else {
                        form = nil
                        status = "No changes."
                    }
                case .viewDefinition:
                    return
                case .filter:
                    if viewDefinitionDraft != nil {
                        let old = (workspace.expression, workspace.text, workspace.view)
                        workspace.expression = editing.fields[0].text
                        workspace.text = editing.fields[1].text
                        do { try refreshViewDefinitionDraft() } catch {
                            workspace.expression = old.0
                            workspace.text = old.1
                            workspace.view = old.2
                            throw error
                        }
                        returnToViewDefinitionForm()
                        status = "Filter staged."
                        return
                    }
                    let departure = navigationEntry
                    let old = (workspace.expression, workspace.text, workspace.view)
                    workspace.expression = editing.fields[0].text
                    workspace.text = editing.fields[1].text
                    workspace.view = nil
                    do { try workspace.refresh(position: 0) } catch {
                        workspace.expression = old.0
                        workspace.text = old.1
                        workspace.view = old.2
                        throw error
                    }
                    form = nil
                    itemIndex = 0
                    navigationHistory.recordDeparture(departure, to: workspace.navigationLocation)
                    status = "Filter applied"
                case .saveView(let replacing):
                    if viewDefinitionDraft != nil {
                        try saveViewDefinition(replacing: replacing)
                        return
                    }
                    guard !editing.fields[0].text.isEmpty else {
                        throw TractandaError("name", "Enter a view name.")
                    }
                    let request = workspace.viewRequest(
                        name: editing.fields[0].text, body: editing.fields[1].text, replacing: replacing)
                    if replacing, let base = workspace.viewToUpdate,
                        request.changes.allSatisfy({ base.fields[$0.key] == $0.value })
                    {
                        form = nil
                        status = "No changes."
                    } else {
                        try queue(request)
                    }
                case .sort(let original):
                    var order: [ItemSort] = []
                    if !editing.fields[0].text.isEmpty {
                        for index in [0, 2] where !editing.fields[index].text.isEmpty {
                            let direction = editing.fields[index + 1].text.lowercased()
                            guard ["ascending", "descending", "asc", "desc"].contains(direction) else {
                                throw TractandaError(
                                    "invalidArguments", "Order must be ascending or descending.")
                            }
                            let target = editing.fields[index].text
                            order.append(
                                try target.hasPrefix("category:")
                                    ? ItemSort(
                                        categoryRootID: String(target.dropFirst("category:".count)),
                                        isAscending: direction.hasPrefix("asc"))
                                    : ItemSort(property: target, isAscending: direction.hasPrefix("asc")))
                        }
                        order.append(contentsOf: original.dropFirst(2))
                    }
                    try ItemSort.validate(order)
                    if viewDefinitionDraft != nil {
                        let old = (workspace.sort, workspace.view)
                        workspace.sort = order
                        do { try refreshViewDefinitionDraft() } catch {
                            workspace.sort = old.0
                            workspace.view = old.1
                            throw error
                        }
                        returnToViewDefinitionForm()
                        status = "Sort staged."
                        return
                    }
                    let departure = navigationEntry
                    let old = (workspace.sort, workspace.view)
                    workspace.sort = order
                    workspace.view = nil
                    do { try workspace.refresh(position: 0) } catch {
                        workspace.sort = old.0
                        workspace.view = old.1
                        throw error
                    }
                    form = nil
                    itemIndex = 0
                    navigationHistory.recordDeparture(departure, to: workspace.navigationLocation)
                    status = "Sort applied to the full server result. S saves; Shift-S saves a new view."
                case .column(let index):
                    guard var editor = columnEditor, let width = Int(editing.fields[2].text) else {
                        throw TractandaError("invalidView", "Enter a column width from 6 to 120.")
                    }
                    let target = editing.fields[0].text
                    let column =
                        try target.hasPrefix("category:")
                        ? ViewColumn(
                            categoryRootID: String(target.dropFirst("category:".count)),
                            title: editing.fields[1].text, width: width,
                            preserving: index.map { editor.columns[$0].value })
                        : ViewColumn(
                            property: target, title: editing.fields[1].text, width: width,
                            preserving: index.map { editor.columns[$0].value })
                    if let index {
                        editor.columns[index] = column
                    } else {
                        editor.columns.append(column)
                        editor.index = editor.columns.count - 1
                    }
                    columnEditor = editor
                    form = nil
                    status = "Column staged. Ctrl-S applies the layout; Esc cancels all column changes."
                }
            }
            return
        case .activate where !editing.isMultiline(editing.focus):
            editing.focus = (editing.focus + 1) % editing.fields.count
        case .copy, .cut, .paste, .undo, .redo, .selectText, .setMark:
            editing.fields[editing.focus].handle(
                command: command!, multiline: editing.isMultiline(editing.focus),
                columns: textColumns, clipboard: clipboard)
        default:
            editing.fields[editing.focus].handle(
                key, multiline: editing.isMultiline(editing.focus), columns: textColumns,
                clipboard: clipboard, keymap: keymap)
        }
        if case .appearance = editing.purpose {
            let fieldsChanged = editing.fields.map(\.text) != originalFieldTexts
            if fieldsChanged, editing.focus == AppearanceFormField.preset,
                let preset = appearancePresetID(editing.fields[AppearanceFormField.preset].text)
            {
                transitionAppearanceForm(&editing, to: preset)
            }
            if let value = try? appearance(from: editing.fields) { appearance = value }
        }
        form = editing
    }

    private func cycleAppearanceField(_ form: inout Form, forward: Bool) {
        let index = form.focus
        let choices: [String]
        switch index {
        case AppearanceFormField.preset: choices = appearance.savedPalettes.map(\.name) + ["Custom"]
        case AppearanceFormField.cursorLayout: choices = CursorLayout.allCases.map(\.rawValue)
        case AppearanceFormField.cursorShape: choices = CursorShape.allCases.map(\.rawValue)
        case AppearanceFormField.cursorBlink: choices = ["steady", "blink"]
        case AppearanceFormField.shadows: choices = ["off", "on"]
        default: choices = AppearanceColor.allCases.map(\.rawValue)
        }
        let current = form.fields[index].text
        let currentIndex = choices.firstIndex { $0.caseInsensitiveCompare(current) == .orderedSame } ?? 0
        let next = (currentIndex + (forward ? 1 : choices.count - 1)) % choices.count
        if index == AppearanceFormField.preset, let preset = appearancePresetID(choices[next]) {
            transitionAppearanceForm(&form, to: preset)
            return
        }
        form.fields[index] = TextBuffer(choices[next])
        if let value = try? appearance(from: form.fields) { appearance = value }
    }

    private func appearancePresetID(_ value: String) -> String? {
        if value.caseInsensitiveCompare("Custom") == .orderedSame { return TerminalAppearance.customPresetID }
        return appearance.palette(namedOrID: value)?.id
    }

    /// All selector routes use this transition. A malformed role field cannot overwrite the
    /// last known Custom palette while the user is merely previewing another saved palette.
    private func transitionAppearanceForm(_ form: inout Form, to preset: String) {
        let purpose = form.purpose
        let cursor = cursorPreferences(from: form.fields) ?? appearance.cursor
        var retained = appearance.customRoles
        if appearance.preset == TerminalAppearance.customPresetID {
            // The selector text may already be the incoming name (for example, typed "Blue").
            // `appearance` is the last fully validated Custom preview and is the only safe
            // snapshot to retain here.
            retained = appearance.roles
        }
        let roles: [AppearanceRole: AppearancePair]
        if preset == TerminalAppearance.customPresetID {
            roles = retained ?? appearance.roles
        } else if let saved = appearance.savedPalettes.first(where: { $0.id == preset }) {
            roles = saved.roles
        } else {
            return
        }
        let value = TerminalAppearance(
            preset: preset, roles: roles, cursor: cursor,
            showsDropShadows: showsDropShadows(from: form.fields) ?? appearance.showsDropShadows,
            customRoles: retained,
            savedPalettes: appearance.savedPalettes)
        appearance = value
        form = appearanceForm(for: value, original: purpose)
    }

    private func cursorPreferences(from fields: [TextBuffer]) -> CursorPreferences? {
        guard fields.count == AppearanceFormField.count,
            let layout = CursorLayout(rawValue: fields[AppearanceFormField.cursorLayout].text.lowercased()),
            let shape = CursorShape(rawValue: fields[AppearanceFormField.cursorShape].text.lowercased()),
            let color = AppearanceColor(rawValue: fields[AppearanceFormField.cursorColor].text),
            ["steady", "blink"].contains(fields[AppearanceFormField.cursorBlink].text.lowercased())
        else { return nil }
        return CursorPreferences(
            layout: layout, shape: shape, color: color,
            blink: fields[AppearanceFormField.cursorBlink].text.caseInsensitiveCompare("blink")
                == .orderedSame)
    }

    private func showsDropShadows(from fields: [TextBuffer]) -> Bool? {
        guard fields.count == AppearanceFormField.count else { return nil }
        switch fields[AppearanceFormField.shadows].text.lowercased() {
        case "off": return false
        case "on": return true
        default: return nil
        }
    }

    private func appearance(from fields: [TextBuffer]) throws -> TerminalAppearance {
        guard let preset = appearancePresetID(fields.first?.text ?? "") else {
            throw TractandaError("invalidAppearance", "Choose a saved color preset or Custom.")
        }
        guard fields.count == AppearanceFormField.count else {
            throw TractandaError("invalidAppearance", "Appearance role values are incomplete.")
        }
        guard let cursor = cursorPreferences(from: fields) else {
            throw TractandaError(
                "invalidAppearance", "Choose a supported cursor layout, shape, color and blink mode.")
        }
        guard let showsDropShadows = showsDropShadows(from: fields) else {
            throw TractandaError("invalidAppearance", "Choose on or off for drop shadows.")
        }
        let roles = try appearanceRoles(from: fields)
        var library = appearance.savedPalettes
        if preset != TerminalAppearance.customPresetID {
            guard let index = library.firstIndex(where: { $0.id == preset }) else {
                throw TractandaError("invalidAppearance", "Choose a saved color preset or Custom.")
            }
            library[index] = AppearancePalette(id: library[index].id, name: library[index].name, roles: roles)
            return TerminalAppearance(
                preset: preset, roles: roles, cursor: cursor, showsDropShadows: showsDropShadows,
                customRoles: appearance.customRoles,
                savedPalettes: library)
        }
        let value = TerminalAppearance(
            preset: TerminalAppearance.customPresetID, roles: roles, cursor: cursor,
            showsDropShadows: showsDropShadows, customRoles: roles,
            savedPalettes: library)
        try value.validate()
        return value
    }

    private func appearanceRoles(from fields: [TextBuffer]) throws -> [AppearanceRole: AppearancePair] {
        var roles: [AppearanceRole: AppearancePair] = [:]
        for (index, role) in AppearanceRole.allCases.enumerated() {
            guard
                let foreground = AppearanceColor(
                    rawValue: fields[AppearanceFormField.foreground(index)].text),
                let background = AppearanceColor(rawValue: fields[AppearanceFormField.background(index)].text)
            else {
                throw TractandaError(
                    "invalidAppearance",
                    "Use a named ANSI color, terminal default, or #RRGGBB for every role.")
            }
            let base = appearance.roles[role] ?? TerminalAppearance.blueFallbackRoles[role]!
            roles[role] = AppearancePair(
                foreground: foreground, background: background, bold: base.bold, dim: base.dim)
        }
        return roles
    }

    private func beginAppearance() {
        if let form, suspendedForm == nil { suspendedForm = form }
        let original = appearance
        form = appearanceForm(for: original, original: .appearance(original))
        status = "Preview changes immediately. Ctrl-S saves locally; Esc restores the prior appearance."
    }

    private func returnFromAppearance() {
        form = suspendedForm
        suspendedForm = nil
    }

    private var categoryNavigatorPreference: Bool {
        categoryWorkspace?.connectedTree ?? retainedCategoryWorkspace?.connectedTree
            ?? viewPreferences.categoryConnectedTree
    }

    /// The preference is shared by the active Categories workspace and the retained one used when
    /// returning from Views.  Keeping both in step makes Ctrl-T and Settings describe one state.
    private func previewCategoryNavigator(_ connectedTree: Bool) {
        if var manager = categoryWorkspace {
            manager.connectedTree = connectedTree
            categoryWorkspace = manager
        }
        if var manager = retainedCategoryWorkspace {
            manager.connectedTree = connectedTree
            retainedCategoryWorkspace = manager
        }
    }

    private func beginCategoryPreferences() {
        if let form, suspendedForm == nil { suspendedForm = form }
        let original = categoryNavigatorPreference
        form = Form(
            purpose: .categoryPreferences(original), title: "Settings / Categories",
            fields: [TextBuffer(original ? "Connected tree" : "Outline")],
            labels: ["Category navigator"])
        status = "Arrows or Space preview the navigator. Ctrl-S saves this profile; Esc restores it."
    }

    private func returnFromCategoryPreferences() {
        form = suspendedForm
        suspendedForm = nil
    }

    private func cycleCategoryNavigator(_ form: inout Form) {
        let connectedTree = form.fields[0].text.caseInsensitiveCompare("Outline") == .orderedSame
        form.fields[0] = TextBuffer(connectedTree ? "Connected tree" : "Outline")
        previewCategoryNavigator(connectedTree)
    }

    private func deleteAppearancePreset(_ form: inout Form) {
        guard let preset = appearancePresetID(form.fields[AppearanceFormField.preset].text),
            preset != TerminalAppearance.customPresetID,
            let index = appearance.savedPalettes.firstIndex(where: { $0.id == preset })
        else {
            status = "Custom is retained separately and cannot be deleted."
            return
        }
        var library = appearance.savedPalettes
        library.remove(at: index)
        let cursor = cursorPreferences(from: form.fields) ?? appearance.cursor
        let retained = appearance.customRoles ?? appearance.roles
        let value = TerminalAppearance(
            preset: TerminalAppearance.customPresetID, roles: retained, cursor: cursor,
            showsDropShadows: showsDropShadows(from: form.fields) ?? appearance.showsDropShadows,
            customRoles: retained,
            savedPalettes: library)
        appearance = value
        form = appearanceForm(for: value, original: form.purpose)
        self.form = form
        status = "Preset deleted in this draft. F8 applies; F9 cancels."
    }

    private func appearanceForm(for value: TerminalAppearance, original: FormPurpose) -> Form {
        var fields = [
            TextBuffer(value.presetDisplayName), TextBuffer(value.cursor.layout.rawValue),
            TextBuffer(value.cursor.shape.rawValue), TextBuffer(value.cursor.color.rawValue),
            TextBuffer(value.cursor.blink ? "blink" : "steady"),
            TextBuffer(value.showsDropShadows ? "on" : "off"),
        ]
        var labels = [
            "Color preset", "Cursor layout", "Cursor shape", "Cursor color", "Cursor blink", "Drop shadows",
        ]
        for role in AppearanceRole.allCases {
            let pair = value.roles[role] ?? TerminalAppearance.blueFallbackRoles[role]!
            fields += [TextBuffer(pair.foreground.rawValue), TextBuffer(pair.background.rawValue)]
            labels += [role.title + " foreground", role.title + " background"]
        }
        assert(fields.count == AppearanceFormField.count)
        return Form(purpose: original, title: "Settings / Appearance", fields: fields, labels: labels)
    }

    private func appearancePresetIsModified(_ form: Form) -> Bool {
        guard case .appearance(let opening) = form.purpose,
            appearance.preset != TerminalAppearance.customPresetID,
            let original = opening.savedPalettes.first(where: { $0.id == appearance.preset }),
            let staged = appearance.savedPalettes.first(where: { $0.id == appearance.preset })
        else { return false }
        return original.roles != staged.roles
    }

    private func beginAppearanceName(from appearanceForm: Form) {
        appearanceFormBeforeNaming = appearanceForm
        form = Form(
            purpose: .appearanceName(appearance), title: "Save appearance preset",
            fields: [TextBuffer("")], labels: ["Preset name"])
        status = "Name a new color preset. F8 saves; F9 returns to Appearance."
    }

    private func handleAppearanceName(_ editing: inout Form, key: TerminalKey, command: TUICommand?) {
        if command == .cancel {
            form = appearanceFormBeforeNaming
            appearanceFormBeforeNaming = nil
            status = "Save-as canceled. Appearance changes remain staged."
            return
        }
        if command == .save || command == .activate {
            execute {
                guard let staged = appearanceFormBeforeNaming else {
                    throw TractandaError("appearance", "Appearance editor is no longer open.")
                }
                let name = editing.fields[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 64,
                    !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                    name.caseInsensitiveCompare("Custom") != .orderedSame
                else { throw TractandaError("name", "Use a nonempty preset name up to 64 characters.") }
                let preview = try appearance(from: staged.fields)
                guard
                    !preview.savedPalettes.contains(where: {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame
                    })
                else {
                    throw TractandaError(
                        "name", "That preset already exists; use Save to update the selected preset.")
                }
                guard preview.savedPalettes.count < TerminalAppearance.maximumSavedPalettes else {
                    throw TractandaError("appearance", "Keep at most 16 saved color presets.")
                }
                guard case .appearance(let opening) = staged.purpose else {
                    throw TractandaError("appearance", "Appearance editor is no longer open.")
                }
                var library = preview.savedPalettes
                if preview.preset != TerminalAppearance.customPresetID,
                    let original = opening.savedPalettes.first(where: { $0.id == preview.preset }),
                    let source = library.firstIndex(where: { $0.id == preview.preset })
                {
                    // Save as forks the selected record from its opening snapshot. Its staged
                    // changes belong to the new palette, while other staged library changes stay.
                    library[source] = original
                }
                let record = AppearancePalette(id: Identifier.make(), name: name, roles: preview.roles)
                let saved = TerminalAppearance(
                    preset: record.id, roles: record.roles, cursor: preview.cursor,
                    customRoles: preview.customRoles, savedPalettes: library + [record])
                try saved.save(to: appearanceURL)
                appearance = saved
                returnFromAppearance()
                appearanceFormBeforeNaming = nil
                status = "Appearance preset \(name) saved locally."
            }
            return
        }
        switch command {
        case .copy, .cut, .paste, .undo, .redo, .selectText, .setMark:
            editing.fields[0].handle(
                command: command!, multiline: false, columns: max(1, columns - 5), clipboard: clipboard)
        default:
            editing.fields[0].handle(
                key, multiline: false, columns: max(1, columns - 5), clipboard: clipboard, keymap: keymap)
        }
        form = editing
    }

    private func beginLearning(categoryID: String) throws {
        let page = LearningWorkspace(client: workspace.client, categoryID: categoryID)
        try page.refresh()
        learning = page
        status = "Review suggestions or E teach from items. F1 explains feedback and shared decisions."
    }

    private func handleLearning(_ command: TUICommand?) {
        guard let learning else { return }
        execute {
            switch command {
            case .cancel:
                self.learning = nil
                try refresh()
                status = "Learning closed."
            case .moveUp: learning.index = max(0, learning.index - 1)
            case .moveDown: learning.index = min(max(0, learning.rows.count - 1), learning.index + 1)
            case .first: learning.index = 0
            case .last: learning.index = max(0, learning.rows.count - 1)
            case .pageUp: learning.index = max(0, learning.index - max(1, rows - 12))
            case .pageDown:
                learning.index = min(max(0, learning.rows.count - 1), learning.index + max(1, rows - 12))
            case .previousResults, .nextResults:
                try learning.loadPage(forward: command == .nextResults)
            case .refresh:
                try learning.refresh()
                status = "Learning refreshed."
            case .learningExamples, .learningSuggestions:
                try learning.refresh(mode: command == .learningExamples ? .examples : .suggestions)
                status =
                    command == .learningExamples
                    ? "A assigns; X excludes. N supplies a negative example; D hides without training."
                    : "A accepts; N rejects; D dismisses. Manual decisions keep their authority."
            case .filter:
                form = Form(
                    purpose: .learningFilter, title: "Filter learning items",
                    fields: [TextBuffer(learning.expression)],
                    labels: ["Spotlight expression (blank shows all)"])
            case .activate: show(try learning.validateCurrent().item)
            case .trainLearning:
                try learning.train()
                status = "Training complete. " + learning.explanation
            case .resetLearning:
                form = Form(
                    purpose: .resetLearning(learning.categoryID),
                    title: "Reset learned model · \(learning.title)",
                    fields: [TextBuffer()], labels: ["Type reset; Ctrl-S confirms"])
                status = "Only your derived model is removed. Assignments, feedback and settings stay."
            case .learningSettings:
                try learning.refresh()
                guard let state = learning.state else { return }
                let draft = LearningSettingsDraft(
                    categoryID: learning.categoryID, revisionID: state.categoryRevisionID,
                    original: state.settings)
                form = Form(
                    purpose: .learningSettings(draft), title: "Learning settings · \(learning.title)",
                    fields: draft.fields, labels: LearningSettingsDraft.labels)
                status = "Ctrl-S saves the category settings once. Automatic classification is not enabled."
            case .acceptLearning, .rejectLearning, .dismissLearning, .excludeLearning, .clearLearningFeedback:
                let action: LearningFeedbackAction
                switch command {
                case .acceptLearning: action = .accept
                case .rejectLearning: action = .negative
                case .dismissLearning: action = .dismiss
                case .excludeLearning: action = .exclude
                default: action = .clear
                }
                try queueLearning(learning.feedback(action))
            default: break
            }
        }
    }

    private func queueLearning(_ edit: LearningEdit) throws {
        try journal.save(edit)
        pendingLearning = edit
        sendPendingLearning()
    }

    private func sendPendingLearning() {
        guard let edit = pendingLearning else { return }
        do {
            let result = try edit.send(using: workspace.client)
            // Cleanup must finish before accepting any new mutation; otherwise keep this exact retry.
            try journal.clear()
            pendingLearning = nil
            form = nil
            panel = nil
            var notice: String
            switch edit {
            case .settings: notice = "Learning settings saved."
            case .feedback(let request):
                switch request.action {
                case .accept: notice = "Accepted: shared category assignment saved."
                case .exclude: notice = "Excluded: shared category exclusion saved."
                case .negative: notice = "Rejected: negative feedback saved; manual assignments kept."
                case .dismiss:
                    notice = "Dismissed: hidden for this content, without training a negative example."
                case .clear: notice = "Feedback cleared; manual assignments and exclusions kept."
                }
            }
            if result.wasReplayed { notice = "Recovered learning edit. " + notice }
            if !result.isIndexReady { notice += " Index needs recovery." }
            do {
                if learning?.categoryID != edit.categoryID {
                    learning = LearningWorkspace(client: workspace.client, categoryID: edit.categoryID)
                }
                try learning?.refresh()
            } catch { notice += " Refresh failed: \(error)" }
            status = notice
        } catch let error as TractandaError where CommitFailure.isDefinitive(error) {
            do { try journal.clear() } catch {
                status = "Cannot clear rejected learning request: \(error). R retries; Q keeps recovery."
                return
            }
            pendingLearning = nil
            learning?.invalidate()
            if error.code == "forbidden" || error.code == "notFound" {
                form = nil
                panel = nil
            }
            status = "\(error). No learning edit applied. Esc cancels a draft; R refreshes before review."
        } catch {
            status = "Unconfirmed learning edit: R retries exactly; Q keeps recovery. \(error)"
        }
    }

    private func queue(_ request: CommitRequest) throws {
        try journal.save(request)  // Persist before the first byte of a mutation is sent.
        pending = PendingEdit(request)
        sendPending()
    }

    private func sendPending() {
        guard let pending else { return }
        do {
            let result = try pending.send(using: workspace.client)
            let savedNewCategory = pending.request.action == .create
            let committedViewDefinition = pending.request.changes["viewDefinition"] != nil
            let categoryManagerBeforeSave:
                (
                    expanded: Set<String>, selectedID: String?, path: [String], all: Bool,
                    replacesCategory: Bool
                )? = {
                    guard activeWorkspace == .categories, picker?.purpose == .categories else { return nil }
                    let replacesCategory: Bool
                    if let form, case .item(let draft) = form.purpose {
                        replacesCategory = draft.isCategory
                    } else {
                        replacesCategory = false
                    }
                    let savedFromInline = categoryWorkspace?.inspector?.base.itemID == pending.request.itemID
                    let changesSelectedCategory =
                        pending.request.itemID == categoryWorkspace?.selectedPath.last?.itemID
                        && categoryWorkspace?.focus == .navigator
                    let selectedID = picker.flatMap { choice in
                        choice.matches.indices.contains(choice.index)
                            ? choice.matches[choice.index].itemID : nil
                    }
                    return picker.map {
                        (
                            $0.expanded, selectedID, categoryWorkspace?.selectedPath.map(\.itemID) ?? [],
                            categoryWorkspace?.selectedAllItems ?? false,
                            replacesCategory || savedFromInline || changesSelectedCategory
                        )
                    }
                }()
            let returnToCategoryManager = categoryManagerBeforeSave != nil
            self.pending = nil
            form = nil
            if !returnToCategoryManager {
                picker = nil
                categoryWorkspace = nil
            }
            panel = nil
            columnEditor = nil
            var cleanupWarning = ""
            do { try journal.clear() } catch { cleanupWarning = " Recovery record retained: \(error)" }
            do {
                if committedViewDefinition {
                    try workspace.openView(result.revision)
                    try reloadViewWorkspace()
                    itemIndex = 0
                    columnOffset = 0
                } else {
                    try refresh()
                    if let categoryManagerBeforeSave {
                        try beginPicker(.categories)
                        if var manager = picker {
                            manager.expanded = categoryManagerBeforeSave.expanded
                            let preferredID = result.revision.itemID
                            manager.index =
                                manager.matches.firstIndex { $0.itemID == preferredID }
                                ?? manager.matches.firstIndex {
                                    $0.itemID == categoryManagerBeforeSave.selectedID
                                } ?? manager.index
                            picker = manager
                            let restoredPath =
                                categoryManagerBeforeSave.replacesCategory
                                ? Array(categoryManagerBeforeSave.path.dropLast()) + [preferredID]
                                : categoryManagerBeforeSave.path
                            if categoryManagerBeforeSave.all, savedNewCategory {
                                if let row = manager.treeRows.index(ofPath: [preferredID]) {
                                    picker?.index = row
                                    selectCategoryWorkspacePath(manager.treeRows[row].path)
                                    categoryWorkspace?.rightMode = .category
                                    categoryWorkspace?.focus = .navigator
                                }
                            } else if categoryManagerBeforeSave.all {
                                selectCategoryWorkspacePath([])
                            } else if let row = manager.treeRows.index(ofPath: restoredPath) {
                                picker?.index = row
                                selectCategoryWorkspacePath(manager.treeRows[row].path)
                                categoryWorkspace?.focus = .right
                                if let index = categoryWorkspace?.preview.rows.firstIndex(where: {
                                    $0.itemID == preferredID
                                }) {
                                    categoryWorkspace?.previewIndex = index
                                }
                            } else if categoryManagerBeforeSave.replacesCategory {
                                let matches = manager.tree?.rows(
                                    filter: result.revision.fields["subject"]?.string ?? "", expanded: [])
                                if let relocated = matches?.first(where: { $0.item.itemID == preferredID }) {
                                    selectCategoryWorkspacePath(ids: relocated.path.map(\.itemID))
                                }
                            }
                        }
                    }
                    itemIndex =
                        workspace.rows.firstIndex { $0.item?.itemID == result.revision.itemID } ?? itemIndex
                }
            } catch { cleanupWarning += " Refresh failed: \(error)" }
            status =
                (result.wasReplayed ? "Recovered saved edit" : "Saved one revision")
                + " · " + String(result.revision.revisionID.prefix(8))
                + (result.isIndexReady ? "" : "; index needs recovery") + cleanupWarning
            // queue() sends synchronously but absorbs failures. Only the confirmed response above can
            // release this staged definition; conflicts and lost responses retain its exact guard.
            if committedViewDefinition { viewDefinitionDraft = nil }
            if let action = categoryDirtyAction {
                categoryDirtyAction = nil
                performCategoryDirtyAction(action)
            }
        } catch let error as TractandaError {
            categoryDirtyAction = nil
            // Only known pre-publication rejections release the frozen request.
            let uncertain = !CommitFailure.isDefinitive(error)
            if !uncertain {
                // A structured native rejection is definitive; the editable draft remains available.
                do {
                    try journal.clear()
                    self.pending = nil
                } catch {
                    status = "Cannot clear rejected request: \(error)"
                    return
                }
                status = "\(error). Draft retained; Esc cancels, then R refreshes."
            } else {
                status = "Unconfirmed edit: R retries exactly; Q quits and preserves recovery. \(error.code)"
            }
        } catch {
            categoryDirtyAction = nil
            status = "Unconfirmed edit: R retries exactly; Q quits and preserves recovery."
        }
    }

    private func show(_ item: Revision) {
        let header =
            "\(item.fields["subject"]?.string ?? "(untitled)")\n\(item.classID)\nItem: \(item.itemID)\nRevision: \(item.revisionID)\n\(item.modifiedAt) · \(item.fields["actor"]?.string ?? "")"
        let body = String((item.fields["body"]?.string ?? "").prefix(65_536))
        panel = ("Item / immutable revision", header + "\n\n" + body)
        panelOffset = 0
    }

    private func showHelp(context: KeyContext) {
        panel = (
            "Tractanda help",
            "Shortcuts · \(context.rawValue)\n\n" + keymap.help(in: context)
                + "\n\nText editing\n" + keymap.help(in: .text) + "\n\n" + """
                    The bottom bar shows F1–F10, optionally F11/F12. View > Function keys chooses Auto, 10 or 12.
                    Auto shows 12 at 110 columns or wider. F11 All items and F12 Refresh are browser conveniences.
                    F10 opens the menu bar: Left/Right switches menus; Up/Down selects; Return executes; Esc closes.
                    Blank function slots have no command. Menus preserve the underlying draft and selection.
                    Mouse: single-click selects; double-click opens a row; wheel scrolls lists, readers and editor text.
                    Click category/section expanders, mark columns, menu entries or the bottom function-key slots.
                    Click an underlined category breadcrumb to reopen that prefix and clear extra filters.
                    The breadcrumb … button lists the full path when it does not fit; double-click or Enter chooses.
                    A breadcrumb ▾ opens its immediate readable child categories. Click a child or press Enter.
                    All items ▾ starts at the readable top-level categories; Cmd-Down/Meta-Down also opens it.
                    Cmd-Down / Meta-Down opens children of the current category; Esc closes the dropdown.
                    Hover over an open menu to select an enabled entry or switch menus; click or Enter runs it.
                    Click editor text to place the cursor; drag or Shift-click (when forwarded) selects text locally.
                    Click Save/Cancel or other labeled controls to run the same commands as the keyboard.
                    View > Mouse turns reporting on/off for this session; --mouse off leaves selection to the terminal.
                    Mouse releases without a matching press, stale geometry and clicks during recovery are ignored.
                    Command shortcuts work when the terminal forwards them. Control alternatives remain available.
                    Meta means Option configured to send Escape, or an Escape prefix followed promptly by the key.
                    Legacy terminals may merge Ctrl-Shift-letter with Ctrl-letter. Shift-S or Meta-Shift-S saves a view as.
                    In text fields, Ctrl-A/E move to line boundaries; Ctrl-B/F move by character; Ctrl-P/N move by line.
                    Ctrl-S saves all fields as one guarded edit. Esc/Ctrl-G/Cmd-W cancel. Tab changes field.
                    Ctrl-U clears the field. Ctrl-K kills to line end; Ctrl-Y yanks. These use the local editing clipboard.
                    Copy/cut/paste and F2/F3/F4 use that same clipboard, shared between fields in this TUI session.
                    Your terminal's own clipboard shortcuts still work when it handles them and sends pasted text.
                    Shift with movement selects text. F7 in the item editor toggles marking; movement extends the mark.
                    Text undo/redo applies to the current draft field, never to a previously saved item revision.

                    Enter focuses the category item list. Meta-Return adds its path to Views; A in the Views report restores all items.
                    Meta-Return in the category manager explicitly adds the chosen path as a filter.
                    Backspace in the browser removes the last category filter.
                    Item marks persist across pages and overlapping sections. Alt-F7 or Shift-M clears all marks.
                    Group operations are limited to 256 items. They keep per-item revision guards and report each result.
                    Confirmation submits the reviewed operation; an interrupted write is retained for exact retry.
                    Current permissions apply to all history. Deletion retains immutable revisions.
                    Categories are ordinary items; deleting a category keeps member items and child categories.
                    Blank the category rule to disable categorization. Starter categories are optional data.
                    Layout/filter/sort changes stay local until Save or Save As stores the view.
                    Category > Learning (Meta-L) reviews one category; in the browser it first asks which category.
                    Learning: T trains, E teaches from items, S reviews suggestions, F filters, [ / ] pages.
                    A accepts/assigns, X excludes, N rejects with a negative example, D dismisses without training.
                    C clears only feedback. Existing manual assignments and exclusions remain authoritative.
                    Feedback changes the shared item; personal category overrides still take precedence.
                    O/F6 opens learning settings; U resets only your derived model, preserving canonical decisions.
                    Learning reads do not train. After changed examples/settings, T explicitly retrains.
                    Stored labels in teaching rows show shared metadata; training counts come from the server.
                    Old negative/dismiss feedback expires when content changes. Scores are not probabilities.
                    Suggestion pages are checked before feedback; stale pages need R refresh and fresh review.
                    Relative-date views refresh every 30 seconds while browsing; drafts are never interrupted.
                    Resize freely. Below 48 columns × 12 rows, enlarge to resume with the draft intact.
                    Further terminal workflows and a keybinding editor remain planned.
                    """
        )
        panelOffset = 0
    }

    private func functionBar(context: KeyContext, width: Int, previewFocused: Bool = false) -> ScreenLine {
        var segments: [ScreenSegment] = []
        var hits: [MouseHit] = []
        var x = 0
        let count = functionKeys.count(columns: width + 1)
        for number in 1...count {
            let slotWidth = width / count + (number <= width % count ? 1 : 0)
            let numberText = TerminalText.fit(String(number), columns: min(slotWidth, String(number).count))
            let commandContext: KeyContext =
                previewFocused ? (activeWorkspace == .categories ? .categories : .browser) : context
            let command = keymap.command(for: KeyChord(.function(number)), in: commandContext)
            // The bar is an executable command surface, so it follows the same availability
            // predicate as F10 instead of advertising bindings that dispatch to no operation.
            let previewCommands: Set<TUICommand> = [
                .help, .commands, .appearance, .refresh, .switchWorkspace, .togglePreview,
                .growPreview, .shrinkPreview, .resetPreview, .toggleSelector, .focusReport,
            ]
            let available: Bool
            if context == .menu, number == 10 {
                available = true
            } else if previewFocused {
                available = command.map { previewCommands.contains($0) } ?? false
            } else {
                available =
                    command.map { $0 == .help || $0 == .commands || isCommandEnabled($0, in: context) }
                    ?? false
            }
            let actionLabel: String
            if let form, case .categoryDirty = form.purpose, number == 9 {
                actionLabel = "Discard"
            } else {
                actionLabel =
                    context == .menu && number == 10
                    ? "Close" : (available ? (command?.functionLabel ?? "") : "")
            }
            let label = TerminalText.fit(
                actionLabel, columns: max(0, slotWidth - numberText.count))
            segments.append(ScreenSegment(text: numberText, style: .key))
            segments.append(ScreenSegment(text: label, style: .functionKeyLabel))
            if available {
                hits.append(MouseHit(columns: x..<(x + slotWidth), target: .function(number)))
            }
            x += slotWidth
        }
        return ScreenLine(text: segments.map(\.text).joined(), style: .header, segments: segments, hits: hits)
    }

    /// Apply all panel shadows after the last overlay has drawn.  Each later rectangle masks an
    /// earlier shadow, while the visible remainder of the earlier shadow stays intact.
    private func applyDropShadows(
        _ rects: [OverlayRect], to lines: inout [ScreenLine], width: Int, height: Int
    ) {
        for index in lines.indices { lines[index].shadowColumns = [] }
        guard appearance.showsDropShadows else { return }
        let bodyLimit = min(lines.count, max(0, height - 2))

        func uncovered(_ span: Range<Int>, row: Int, by later: ArraySlice<OverlayRect>) -> [Range<Int>] {
            var remaining = [span]
            for rect in later where (rect.y..<(rect.y + rect.height)).contains(row) {
                let covered = max(0, rect.x)..<min(width, rect.x + rect.width)
                remaining = remaining.flatMap { range -> [Range<Int>] in
                    guard range.overlaps(covered) else { return [range] }
                    var pieces: [Range<Int>] = []
                    if range.lowerBound < covered.lowerBound {
                        pieces.append(range.lowerBound..<min(range.upperBound, covered.lowerBound))
                    }
                    if covered.upperBound < range.upperBound {
                        pieces.append(max(range.lowerBound, covered.upperBound)..<range.upperBound)
                    }
                    return pieces
                }
            }
            return remaining.filter { !$0.isEmpty }
        }

        for (index, rect) in rects.enumerated() where rect.width > 0 && rect.height > 0 {
            let later = rects.dropFirst(index + 1)
            let right = max(0, rect.x + rect.width)..<min(width, rect.x + rect.width + 2)
            if !right.isEmpty {
                for row in max(0, rect.y + 1)..<min(bodyLimit, rect.y + rect.height + 1) {
                    lines[row].shadowColumns += uncovered(right, row: row, by: later)
                }
            }
            let bottom = max(0, rect.x + 2)..<min(width, rect.x + rect.width + 2)
            let bottomRow = rect.y + rect.height
            if !bottom.isEmpty, (0..<bodyLimit).contains(bottomRow) {
                lines[bottomRow].shadowColumns += uncovered(bottom, row: bottomRow, by: later)
            }
        }
    }

    private func itemFormTextWidth() -> Int {
        let screenWidth = max(1, columns - 1)
        let panelWidth = min(screenWidth, max(28, min(96, screenWidth - (columns >= 80 ? 6 : 0))))
        return max(1, panelWidth - 2 - 18)
    }

    /// Item drafts use the same guarded whole-edit implementation as before, but live above their
    /// report or category manager.  Keeping the background rendered makes a long edit much less
    /// disorienting and, because the overlay owns all hits, it cannot accidentally operate it.
    private func overlayItemForm(on lines: inout [ScreenLine], width: Int, height: Int) -> OverlayRect? {
        guard let form, case .item = form.purpose, height >= 12 else { return nil }
        for index in lines.indices {
            lines[index].style = .dimmed
            lines[index].segments = []
            lines[index].hits = []
            lines[index].selectionColumns = []
            lines[index].cursorColumn = nil
        }
        let usableHeight = max(1, height - 2)
        let panelWidth = min(width, max(28, min(96, width - (columns >= 80 ? 6 : 0))))
        let inner = max(1, panelWidth - 2)
        let panelHeight = min(usableHeight, max(8, min(usableHeight - (height >= 25 ? 2 : 0), 26)))
        let x = max(0, (width - panelWidth) / 2)
        let y = max(0, (usableHeight - panelHeight) / 2)
        let focused = min(form.focus, form.fields.count - 1)
        let labelWidth = 18
        let textWidth = itemFormTextWidth()

        func visibleLabel(_ field: Int) -> String {
            if field == 3 { return "Category rule" }
            if field == 2, case .item(let draft) = form.purpose {
                _ = draft
                return "Class"
            }
            return form.labels[field]
        }

        struct EditorRow {
            let field: Int
            let line: TextBuffer.DisplayLine
            let label: String?
        }
        func display(_ field: Int, multiline: Bool = false) -> [TextBuffer.DisplayLine] {
            form.fields[field].displayLines(
                columns: textWidth, marked: focused == field, flatten: !multiline,
                cursorLayout: appearance.cursor.layout)
        }
        func focusedLine(_ field: Int) -> TextBuffer.DisplayLine {
            let values = display(field)
            return values.first(where: \.containsCursor) ?? values[0]
        }

        var content: [EditorRow] = []
        if panelHeight <= 10 {
            let values = display(focused, multiline: form.isMultiline(focused))
            let caret = values.firstIndex(where: \.containsCursor) ?? 0
            let count = max(1, panelHeight - 5)
            let maximum = max(0, values.count - count)
            let start = min(maximum, max(0, form.scrollOffset ?? (caret - count + 1)))
            editorViewport = (focused, start, maximum)
            content = values.dropFirst(start).prefix(count).enumerated().map {
                EditorRow(
                    field: focused, line: $0.element, label: $0.offset == 0 ? visibleLabel(focused) : nil)
            }
        } else {
            content.append(EditorRow(field: 0, line: focusedLine(0), label: visibleLabel(0)))
            let fixed = 3  // subject, class and rule each occupy one row
            let bodyCount = max(2, panelHeight - 5 - fixed)
            let values = display(1, multiline: true)
            let caret = values.firstIndex(where: \.containsCursor) ?? 0
            let maximum = max(0, values.count - bodyCount)
            let start = min(maximum, max(0, form.scrollOffset ?? (caret - bodyCount + 1)))
            if focused == 1 {
                self.form?.scrollOffset = start
                editorViewport = (1, start, maximum)
            }
            content += values.dropFirst(start).prefix(bodyCount).enumerated().map {
                EditorRow(field: 1, line: $0.element, label: $0.offset == 0 ? visibleLabel(1) : nil)
            }
            content.append(EditorRow(field: 2, line: focusedLine(2), label: visibleLabel(2)))
            content.append(EditorRow(field: 3, line: focusedLine(3), label: visibleLabel(3)))
        }
        let capacity = panelHeight - 4
        if content.count > capacity { content = Array(content.prefix(capacity)) }

        func popup(
            _ content: String, row: Int, style: ScreenStyle = .menu, hits: [MouseHit] = [],
            cursorColumn: Int? = nil, selectionColumns: [Range<Int>] = []
        ) {
            guard lines.indices.contains(row) else { return }
            let box = "│" + TerminalText.fit(content, columns: inner) + "│"
            let overlay = ScreenLine.popup(
                box, over: lines[row].text, column: x, boxWidth: panelWidth, width: width, style: style)
            let segments = overlay.segments.enumerated().map {
                ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? style : .dimmed)
            }
            lines[row] = ScreenLine(
                text: overlay.text, segments: segments, hits: hits, selectionColumns: selectionColumns,
                borderColumns: overlay.borderColumns, borderStyle: overlay.borderStyle,
                cursorColumn: cursorColumn)
        }
        func border(_ content: String, row: Int) {
            guard lines.indices.contains(row) else { return }
            let overlay = ScreenLine.popup(
                content, over: lines[row].text, column: x, boxWidth: panelWidth, width: width, style: .menu)
            let segments = overlay.segments.enumerated().map {
                ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? .menu : .dimmed)
            }
            lines[row] = ScreenLine(
                text: overlay.text, segments: segments, borderColumns: overlay.borderColumns,
                borderStyle: overlay.borderStyle)
        }

        border("╭" + String(repeating: "─", count: inner) + "╮", row: y)
        popup(
            " "
                + TerminalText.fit(
                    form.title + " · " + visibleLabel(focused) + " · \(focused + 1)/\(form.fields.count)",
                    columns: inner - 1),
            row: y + 1, style: .header)
        for offset in 0..<capacity {
            let row = y + 2 + offset
            guard content.indices.contains(offset) else {
                popup("", row: row)
                continue
            }
            let item = content[offset]
            let label = item.label.map { "\(item.field == focused ? ">" : " ") \($0): " } ?? "    "
            let value = TerminalText.fit(item.line.text, columns: max(1, inner - labelWidth))
            let rowHits = [
                MouseHit(columns: (x + 1)..<(x + panelWidth - 1), target: .field(item.field)),
                MouseHit(
                    columns: (x + 1 + labelWidth)..<(x + panelWidth - 1),
                    target: .fieldText(item.field, item.line.offsets)),
            ]
            popup(
                TerminalText.fit(label, columns: labelWidth) + value,
                row: row,
                style: item.field == focused ? .menuSelection : .menu,
                hits: rowHits,
                cursorColumn: item.field == focused
                    ? item.line.cursorColumn.map { x + 1 + labelWidth + $0 } : nil,
                selectionColumns: item.line.selectionColumns.map {
                    (x + 1 + labelWidth + $0.lowerBound)..<(x + 1 + labelWidth + $0.upperBound)
                })
        }
        let actionLine = ScreenLine.controls(
            [("Ctrl-S/F8 Save", .save), ("Esc/F9 Cancel", .cancel)], style: .header)
        popup(
            TerminalText.fit(actionLine.text, columns: inner), row: y + panelHeight - 2, style: .header,
            hits: actionLine.hits.map {
                MouseHit(
                    columns: (x + 1 + $0.columns.lowerBound)..<(x + 1 + $0.columns.upperBound),
                    target: $0.target)
            })
        border("╰" + String(repeating: "─", count: inner) + "╯", row: y + panelHeight - 1)
        return OverlayRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    private func overlayCategoryDirty(on lines: inout [ScreenLine], width: Int, height: Int) -> OverlayRect? {
        guard let form, case .categoryDirty = form.purpose else { return nil }
        for index in lines.indices {
            lines[index].style = .dimmed
            lines[index].segments = []
            lines[index].hits = []
        }
        let boxWidth = min(width, 58)
        let x = max(0, (width - boxWidth) / 2)
        let y = max(0, (height - 2 - 7) / 2)
        let inner = boxWidth - 2
        func put(_ text: String, row: Int, style: ScreenStyle, hits: [MouseHit] = []) {
            guard lines.indices.contains(row) else { return }
            let popup = ScreenLine.popup(
                text, over: lines[row].text, column: x, boxWidth: boxWidth, width: width, style: style)
            lines[row] = ScreenLine(
                text: popup.text,
                segments: popup.segments.enumerated().map {
                    ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? style : .dimmed)
                },
                hits: hits, borderColumns: popup.borderColumns, borderStyle: popup.borderStyle)
        }
        put("╭" + String(repeating: "─", count: inner) + "╮", row: y, style: .menu)
        put(
            "│" + TerminalText.fit(" Unsaved category draft", columns: inner) + "│", row: y + 1,
            style: .header)
        put(
            "│" + TerminalText.fit(" Save changes before leaving this category?", columns: inner) + "│",
            row: y + 2, style: .menu)
        put(
            "│"
                + TerminalText.fit(
                    " Choose an action. Esc stays with this edit.", columns: inner) + "│",
            row: y + 3, style: .menu)
        put("│" + String(repeating: " ", count: inner) + "│", row: y + 4, style: .menu)
        let controls = ScreenLine.controls(
            [("F8 Save", .save), ("F9 Discard", .cancel), ("Esc Stay", .cancel)], style: .header)
        put(
            "│" + TerminalText.fit(controls.text, columns: inner) + "│", row: y + 5, style: .header,
            hits: controls.hits.enumerated().map { index, hit in
                MouseHit(
                    columns: (x + 1 + hit.columns.lowerBound)..<(x + 1 + hit.columns.upperBound),
                    target: index == 1
                        ? .categoryDirtyDiscard : .command(hit.target == .command(.save) ? .save : .cancel))
            })
        // The three short ASCII action labels share the menu selection role. Borders remain
        // explicit frame cells, and Unicode in the dimmed background keeps its existing segments.
        let selected = controls.hits[min(2, max(0, form.focus))].columns
        var actionSegments = lines[y + 5].segments
        if actionSegments.count == 3 {
            let box = Array(actionSegments[1].text)
            let lower = min(box.count, selected.lowerBound + 1)
            let upper = min(box.count, selected.upperBound + 1)
            actionSegments.replaceSubrange(
                1...1,
                with: [
                    ScreenSegment(text: String(box[..<lower]), style: .header),
                    ScreenSegment(text: String(box[lower..<upper]), style: .menuSelection),
                    ScreenSegment(text: String(box[upper...]), style: .header),
                ])
            lines[y + 5].segments = actionSegments
        }
        put("╰" + String(repeating: "─", count: inner) + "╯", row: y + 6, style: .menu)
        return OverlayRect(x: x, y: y, width: boxWidth, height: 7)
    }

    /// Appearance is a small table overlay, not the generic one-field-at-a-time form.  Color
    /// fields still accept a validated #RRGGBB literal, while arrows cycle the common palette.
    private func overlayAppearanceForm(on lines: inout [ScreenLine], width: Int, height: Int) -> OverlayRect?
    {
        guard let active = form else { return nil }
        let form: Form
        switch active.purpose {
        case .appearance: form = active
        case .appearanceName:
            guard let retained = appearanceFormBeforeNaming else { return nil }
            form = retained
        default: return nil
        }
        for index in lines.indices {
            lines[index].style = .dimmed
            lines[index].segments = []
            lines[index].hits = []
            lines[index].cursorColumn = nil
        }
        struct Row {
            let fields: [Int]
            let title: String
            let isSection: Bool
        }
        let rows: [Row] =
            [
                Row(fields: [AppearanceFormField.preset], title: "Appearance preset", isSection: false),
                Row(fields: [], title: "Cursor", isSection: true),
                Row(fields: [AppearanceFormField.cursorLayout], title: "Cursor layout", isSection: false),
                Row(fields: [AppearanceFormField.cursorShape], title: "Cursor shape", isSection: false),
                Row(fields: [AppearanceFormField.cursorColor], title: "Cursor color", isSection: false),
                Row(fields: [AppearanceFormField.cursorBlink], title: "Cursor blink", isSection: false),
                Row(fields: [], title: "Effects", isSection: true),
                Row(fields: [AppearanceFormField.shadows], title: "Drop shadows", isSection: false),
                Row(fields: [], title: "Interface colors", isSection: true),
            ]
            + AppearanceRole.allCases.enumerated().map {
                Row(
                    fields: [
                        AppearanceFormField.foreground($0.offset), AppearanceFormField.background($0.offset),
                    ], title: $0.element.title, isSection: false)
            }
        // On compact terminals reserve a bottom cell row for the shadow.  A right gutter is used
        // only once the four footer actions still fit without truncation.
        let usableHeight = max(1, height - 2 - (appearance.showsDropShadows ? 1 : 0))
        let shadowGutter = appearance.showsDropShadows && width >= 50 ? 3 : 0
        let panelWidth = min(width - shadowGutter, max(34, min(104, width - shadowGutter)))
        let inner = max(1, panelWidth - 2)
        // Let a normal 80×25 terminal show the complete grouped form; compact terminals scroll
        // rows while retaining the title and function-key footer.
        let panelHeight = min(usableHeight, max(8, rows.count + 4))
        let x = max(0, (width - panelWidth) / 2)
        let y = max(0, (usableHeight - panelHeight) / 2)
        let labelWidth = min(30, max(14, inner / 3))

        func popup(
            _ content: String, row: Int, style: ScreenStyle = .menu, hits: [MouseHit] = [],
            cursorColumn: Int? = nil, selectionColumns: [Range<Int>] = []
        ) {
            guard lines.indices.contains(row) else { return }
            let box = "│" + TerminalText.fit(content, columns: inner) + "│"
            let overlay = ScreenLine.popup(
                box, over: lines[row].text, column: x, boxWidth: panelWidth, width: width, style: style)
            let segments = overlay.segments.enumerated().map {
                ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? style : .dimmed)
            }
            lines[row] = ScreenLine(
                text: overlay.text, segments: segments, hits: hits,
                selectionColumns: selectionColumns,
                borderColumns: overlay.borderColumns, borderStyle: overlay.borderStyle,
                cursorColumn: cursorColumn)
        }
        func border(_ content: String, row: Int) {
            guard lines.indices.contains(row) else { return }
            let overlay = ScreenLine.popup(
                content, over: lines[row].text, column: x, boxWidth: panelWidth, width: width, style: .menu)
            let segments = overlay.segments.enumerated().map {
                ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? .menu : .dimmed)
            }
            lines[row] = ScreenLine(
                text: overlay.text, segments: segments, borderColumns: overlay.borderColumns,
                borderStyle: overlay.borderStyle)
        }
        let roleValueWidth = max(1, (inner - labelWidth - 4) / 2)
        border("╭" + String(repeating: "─", count: inner) + "╮", row: y)
        let focusedSection = AppearanceFormField.section(for: form.focus)
        let hint =
            AppearanceFormField.isColor(form.focus)
            ? "Name or #RRGGBB · Ctrl-U replace"
            : "Tab/arrows change · live preview"
        let modified = appearancePresetIsModified(form) ? " · modified" : ""
        let header =
            inner < 52
            ? " Settings / Appearance · \(AppearanceFormField.isColor(form.focus) ? (form.focus == AppearanceFormField.cursorColor ? "Cursor" : "Colors") : focusedSection)\(AppearanceFormField.isColor(form.focus) ? " · #RRGGBB" : "")\(modified)"
            : TerminalText.fit(" Settings / Appearance · \(focusedSection)", columns: labelWidth) + " "
                + TerminalText.fit(hint + modified, columns: inner - labelWidth - 1)
        popup(header, row: y + 1, style: .header)
        let actions = ScreenLine.controls(
            [
                ("F5 Save as", .saveAs), ("F6 Delete", .deleteAppearancePreset),
                ("F8 Save", .save), ("F9 Cancel", .cancel),
            ],
            style: .header)
        popup(
            TerminalText.fit(actions.text, columns: inner), row: y + panelHeight - 2, style: .header,
            hits: actions.hits.map {
                MouseHit(
                    columns: (x + 1 + $0.columns.lowerBound)..<(x + 1 + $0.columns.upperBound),
                    target: $0.target)
            })
        border("╰" + String(repeating: "─", count: inner) + "╯", row: y + panelHeight - 1)

        let focusedRow = rows.firstIndex { $0.fields.contains(form.focus) } ?? 0
        let capacity = max(1, panelHeight - 4)
        let start = min(max(0, rows.count - capacity), max(0, focusedRow - capacity + 1))
        for displayIndex in 0..<capacity {
            let row = y + 2 + displayIndex
            guard rows.indices.contains(start + displayIndex) else {
                popup("", row: row)
                continue
            }
            let entry = rows[start + displayIndex]
            if entry.isSection {
                if entry.title != AppearanceFormField.section(for: AppearanceFormField.firstRole) {
                    popup("  \(entry.title)", row: row, style: .header)
                    continue
                }
                let sectionHeader =
                    TerminalText.fit("  \(entry.title)", columns: labelWidth) + " "
                    + TerminalText.fit("FG", columns: roleValueWidth) + " │ "
                    + TerminalText.fit("BG", columns: roleValueWidth)
                popup(sectionHeader, row: row, style: .header)
                continue
            }
            let first = entry.fields[0]
            let isFocused = entry.fields.contains(form.focus)
            let valueWidth =
                entry.fields.count == 2
                ? roleValueWidth : max(1, inner - labelWidth - 1)
            // The value follows the fixed-width label and its separating space inside the left
            // border.  Hits, caret and selection spans must share this exact origin.
            let valueStart = x + 2 + labelWidth
            let values = entry.fields.map { index -> TextBuffer.DisplayLine in
                form.fields[index].displayLines(
                    columns: valueWidth,
                    marked: index == form.focus, flatten: true, cursorLayout: appearance.cursor.layout
                ).first!
            }
            let separator = entry.fields.count == 2 ? " │ " : ""
            let value = values.enumerated().map { offset, line in
                let display: String
                if entry.fields[offset] == AppearanceFormField.cursorLayout,
                    line.text == CursorLayout.native.rawValue
                {
                    display = "Standard"
                } else if entry.fields[offset] == AppearanceFormField.cursorLayout,
                    line.text == CursorLayout.gap.rawValue
                {
                    display = "Insertion gap"
                } else {
                    display = line.text
                }
                return TerminalText.fit(display, columns: valueWidth)
            }.joined(separator: separator)
            var hits = [MouseHit](
                repeating: MouseHit(columns: 0..<0, target: .field(first)), count: 0)
            var column = valueStart
            for (offset, field) in entry.fields.enumerated() {
                let line = values[offset]
                hits.append(
                    MouseHit(
                        columns: column..<min(x + panelWidth - 1, column + valueWidth),
                        target: .fieldText(field, line.offsets)))
                column += valueWidth + (offset + 1 == entry.fields.count ? 0 : 3)
            }
            let cursorColumn: Int? =
                isFocused
                ? {
                    guard let focusedOffset = entry.fields.firstIndex(of: form.focus),
                        let local = values[focusedOffset].cursorColumn
                    else { return nil }
                    return valueStart + focusedOffset * (valueWidth + 3) + local
                }() : nil
            let compactTitle: String
            if inner < 52, entry.title == "Function-key number" {
                compactTitle = "Key numbers"
            } else if inner < 52, entry.title == "Function-key label" {
                compactTitle = "Key labels"
            } else {
                compactTitle = entry.title
            }
            popup(
                TerminalText.fit((isFocused ? "> " : "  ") + compactTitle, columns: labelWidth)
                    + " " + TerminalText.fit(value, columns: inner - labelWidth - 1), row: row,
                style: isFocused ? .menuSelection : .menu, hits: hits,
                cursorColumn: cursorColumn,
                selectionColumns: values.enumerated().flatMap { offset, line in
                    line.selectionColumns.map {
                        let base = valueStart + offset * (valueWidth + 3)
                        return (base + $0.lowerBound)..<(base + $0.upperBound)
                    }
                })
        }
        return OverlayRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    private func overlayAppearanceName(on lines: inout [ScreenLine], width: Int, height: Int) -> OverlayRect?
    {
        guard let form, case .appearanceName = form.purpose else { return nil }
        for index in lines.indices {
            lines[index].hits = []
            lines[index].cursorColumn = nil
            lines[index].selectionColumns = []
        }
        let panelWidth = min(max(30, width - 8), 58)
        let inner = panelWidth - 2
        let x = max(0, (width - panelWidth) / 2)
        let y = max(0, (height - 7) / 2)
        func put(_ text: String, row: Int, style: ScreenStyle, hits: [MouseHit] = [], cursor: Int? = nil) {
            guard lines.indices.contains(row) else { return }
            let overlay = ScreenLine.popup(
                "│" + TerminalText.fit(text, columns: inner) + "│", over: lines[row].text,
                column: x, boxWidth: panelWidth, width: width, style: style)
            lines[row] = ScreenLine(
                text: overlay.text,
                segments: overlay.segments.enumerated().map {
                    ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? style : .dimmed)
                }, hits: hits, borderColumns: overlay.borderColumns, borderStyle: overlay.borderStyle,
                cursorColumn: cursor)
        }
        func border(_ text: String, _ row: Int) {
            guard lines.indices.contains(row) else { return }
            let overlay = ScreenLine.popup(
                text, over: lines[row].text, column: x, boxWidth: panelWidth, width: width, style: .menu)
            lines[row] = ScreenLine(
                text: overlay.text,
                segments: overlay.segments.enumerated().map {
                    ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? .menu : .dimmed)
                }, borderColumns: overlay.borderColumns, borderStyle: overlay.borderStyle)
        }
        border("╭" + String(repeating: "─", count: inner) + "╮", y)
        put(" Save appearance preset", row: y + 1, style: .header)
        let line = form.fields[0].displayLines(
            columns: max(1, inner - 4), marked: true, flatten: true, cursorLayout: appearance.cursor.layout
        ).first!
        put(
            "> " + line.text, row: y + 2, style: .activeSelection,
            hits: [MouseHit(columns: (x + 3)..<(x + panelWidth - 1), target: .fieldText(0, line.offsets))],
            cursor: line.cursorColumn.map { x + 3 + $0 })
        if lines.indices.contains(y + 2) {
            lines[y + 2].selectionColumns = line.selectionColumns.map {
                (x + 3 + $0.lowerBound)..<(x + 3 + $0.upperBound)
            }
        }
        put("", row: y + 3, style: .menu)
        put(
            "F8/Enter save · F9/Esc cancel", row: y + 4, style: .header,
            hits: [
                MouseHit(columns: (x + 1)..<(x + 14), target: .command(.save)),
                MouseHit(columns: (x + 17)..<(x + panelWidth - 1), target: .command(.cancel)),
            ])
        border("╰" + String(repeating: "─", count: inner) + "╯", y + 5)
        return OverlayRect(x: x, y: y, width: panelWidth, height: 6)
    }

    private func overlayCategoryPreferences(on lines: inout [ScreenLine], width: Int, height: Int)
        -> OverlayRect?
    {
        guard let form, case .categoryPreferences = form.purpose else { return nil }
        for index in lines.indices {
            lines[index].style = .dimmed
            lines[index].segments = []
            lines[index].hits = []
            lines[index].cursorColumn = nil
            lines[index].selectionColumns = []
        }
        let panelWidth = min(max(38, width - 8), 58)
        let inner = panelWidth - 2
        let x = max(0, (width - panelWidth) / 2)
        let y = max(0, (height - 9) / 2)
        func put(_ text: String, row: Int, style: ScreenStyle, hits: [MouseHit] = []) {
            guard lines.indices.contains(row) else { return }
            let overlay = ScreenLine.popup(
                "│" + TerminalText.fit(text, columns: inner) + "│", over: lines[row].text,
                column: x, boxWidth: panelWidth, width: width, style: style)
            lines[row] = ScreenLine(
                text: overlay.text,
                segments: overlay.segments.enumerated().map {
                    ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? style : .dimmed)
                }, hits: hits, borderColumns: overlay.borderColumns, borderStyle: overlay.borderStyle)
        }
        func border(_ text: String, _ row: Int) {
            guard lines.indices.contains(row) else { return }
            let overlay = ScreenLine.popup(
                text, over: lines[row].text, column: x, boxWidth: panelWidth, width: width, style: .menu)
            lines[row] = ScreenLine(
                text: overlay.text,
                segments: overlay.segments.enumerated().map {
                    ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? .menu : .dimmed)
                }, borderColumns: overlay.borderColumns, borderStyle: overlay.borderStyle)
        }
        border("╭" + String(repeating: "─", count: inner) + "╮", y)
        put(" Settings / Categories", row: y + 1, style: .header)
        put("  Category navigator", row: y + 2, style: .menu)
        put(
            "  > " + form.fields[0].text, row: y + 3, style: .menuSelection,
            hits: [MouseHit(columns: (x + 1)..<(x + panelWidth - 1), target: .command(.toggle))])
        put("  Stored privately for this connection profile.", row: y + 4, style: .menu)
        put("  Arrow keys or Space changes the preview.", row: y + 5, style: .menu)
        put(
            " F8 Save                 F9 Cancel", row: y + 6, style: .header,
            hits: [
                MouseHit(columns: (x + 1)..<(x + 13), target: .command(.save)),
                MouseHit(columns: (x + 25)..<(x + panelWidth - 1), target: .command(.cancel)),
            ])
        border("╰" + String(repeating: "─", count: inner) + "╯", y + 7)
        return OverlayRect(x: x, y: y, width: panelWidth, height: 8)
    }

    /// A definition is deliberately modal: the report remains visible (but inactive) so a user can
    /// keep its context while editing.  The small terminal variant uses the same state and simply
    /// gives the panel almost all available rows.
    private func viewFormGeometry() -> (width: Int, inner: Int, label: Int, key: Int, title: Int) {
        let screenWidth = max(1, columns - 1)
        let width = min(screenWidth, max(20, min(screenWidth - (columns >= 80 ? 6 : 0), 100)))
        let inner = max(1, width - 2)
        let key = max(6, (inner - 15) * 45 / 100)
        return (width, inner, min(22, inner / 2), key, max(6, inner - 15 - key))
    }

    private func viewFormTextWidth(_ control: ViewDefinitionForm.Control) -> Int {
        let geometry = viewFormGeometry()
        switch control {
        case .column(_, .property): return geometry.key
        case .column(_, .title): return geometry.title
        case .column(_, .width): return 6
        case .primaryProperty, .secondaryProperty: return max(1, geometry.inner - 29)
        default: return max(1, geometry.inner - geometry.label)
        }
    }

    private func overlayViewDefinitionForm(on lines: inout [ScreenLine], width: Int, height: Int)
        -> OverlayRect?
    {
        guard let form, case .viewDefinition = form.purpose, let draft = viewDefinitionDraft else {
            return nil
        }
        let definition = draft.form
        let controls = definition.controls
        guard !controls.isEmpty, height >= 12 else { return nil }
        for index in lines.indices {
            lines[index].style = .dimmed
            lines[index].segments = []
            lines[index].hits = []
        }
        let geometry = viewFormGeometry()
        let panelWidth = geometry.width
        let inner = geometry.inner
        let usableHeight = height - 2
        let panelHeight = height >= 25 ? min(usableHeight - 2, 24) : usableHeight
        let x = max(0, (width - panelWidth) / 2)
        let y = max(0, (usableHeight - panelHeight) / 2)
        let focused = min(form.focus, controls.count - 1)

        struct Row {
            var segments: [ScreenSegment]
            var hits: [MouseHit]
            var controls: [Int]
            var containsCursor = false
            var cursorColumn: Int?
            var selectionColumns: [Range<Int>] = []
        }
        func cellWidth(_ text: String) -> Int { text.reduce(0) { $0 + TerminalText.width($1) } }
        func displayed(_ control: Int, width: Int, flatten: Bool = true) -> [TextBuffer.DisplayLine] {
            definition.displayLines(
                controls[control], columns: width, marked: focused == control, flatten: flatten,
                cursorLayout: appearance.cursor.layout)
        }
        func singleLine(_ control: Int, width: Int) -> TextBuffer.DisplayLine {
            let display = displayed(control, width: width)
            return display.first(where: \.containsCursor) ?? display[0]
        }
        func textHit(_ control: Int, start: Int, width: Int, offsets: [Int]) -> MouseHit {
            MouseHit(
                columns: (x + 1 + start)..<(x + 1 + start + width),
                target: .viewDefinitionText(control, offsets))
        }
        var rows: [Row] = []
        for index in 0..<7 {
            let control = controls[index]
            let textWidth = viewFormTextWidth(control)
            let display = displayed(index, width: textWidth, flatten: !definition.isMultiline(control))
            let selectedLine = display.firstIndex(where: \.containsCursor) ?? 0
            let visibleCount = definition.isMultiline(control) ? 2 : 1
            let first =
                definition.isMultiline(control) ? max(0, selectedLine - visibleCount + 1) : selectedLine
            for offset in 0..<visibleCount {
                let displayIndex = first + offset
                let line = display.indices.contains(displayIndex) ? display[displayIndex] : nil
                let label = offset == 0 ? control.label + ":" : ""
                let prefix = (focused == index ? ">" : " ") + label
                let text = line?.text ?? ""
                var hits = [
                    MouseHit(
                        columns: (x + 1)..<(x + panelWidth - 1),
                        target: .viewDefinitionControl(index))
                ]
                if definition.isText(control) {
                    hits.append(
                        textHit(
                            index, start: geometry.label, width: textWidth,
                            offsets: line?.offsets ?? display.last!.offsets.suffix(1).map { $0 }))
                }
                rows.append(
                    Row(
                        segments: [
                            ScreenSegment(
                                text: TerminalText.fit(prefix, columns: geometry.label), style: .menu),
                            ScreenSegment(
                                text: TerminalText.fit(text, columns: textWidth),
                                style: focused == index ? .menuSelection : .menu),
                        ], hits: hits, controls: [index], containsCursor: line?.containsCursor ?? false,
                        cursorColumn: line?.cursorColumn.map { geometry.label + $0 },
                        selectionColumns: (line?.selectionColumns ?? []).map {
                            (geometry.label + $0.lowerBound)..<(geometry.label + $0.upperBound)
                        }))
            }
        }
        for (property, direction, title) in [(7, 8, "Primary sort:"), (9, 10, "Secondary sort:")] {
            let labelWidth = 15
            let keyWidth = viewFormTextWidth(controls[property])
            let key = singleLine(property, width: keyWidth)
            let directionWidth = 12
            let directionText = definition.display(controls[direction])
            let directionStart = labelWidth + keyWidth + 2
            rows.append(
                Row(
                    segments: [
                        ScreenSegment(text: TerminalText.fit(" " + title, columns: labelWidth), style: .menu),
                        ScreenSegment(
                            text: TerminalText.fit(key.text, columns: keyWidth),
                            style: focused == property ? .menuSelection : .menu),
                        ScreenSegment(text: "  ", style: .menu),
                        ScreenSegment(
                            text: TerminalText.fit(directionText, columns: directionWidth),
                            style: focused == direction ? .menuSelection : .menu),
                    ],
                    hits: [
                        MouseHit(
                            columns: (x + 1)..<(x + 1 + directionStart),
                            target: .viewDefinitionControl(property)),
                        textHit(property, start: labelWidth, width: keyWidth, offsets: key.offsets),
                        MouseHit(
                            columns: (x + 1 + directionStart)..<(x + panelWidth - 1),
                            target: .viewDefinitionControl(direction)),
                    ], controls: [property, direction], containsCursor: key.containsCursor,
                    cursorColumn: key.cursorColumn.map { labelWidth + $0 },
                    selectionColumns: key.selectionColumns.map {
                        (labelWidth + $0.lowerBound)..<(labelWidth + $0.upperBound)
                    }))
        }
        let widths = [geometry.key, geometry.title, 6]
        rows.append(
            Row(
                segments: [
                    ScreenSegment(
                        text: " # "
                            + zip(["Key", "Heading", "Width"], widths).map {
                                TerminalText.fit($0.0, columns: $0.1)
                            }.joined(separator: " | "), style: .header)
                ], hits: [], controls: []))
        for column in definition.columns.indices {
            let base = 11 + column * 3
            var segments = [
                ScreenSegment(text: TerminalText.fit(" \(column + 1) ", columns: 3), style: .menu)
            ]
            var hits: [MouseHit] = []
            var position = 3
            var cursorColumn: Int?
            var selectionColumns: [Range<Int>] = []
            for part in 0..<3 {
                if part > 0 {
                    segments.append(ScreenSegment(text: " | ", style: .menu))
                    position += 3
                }
                let control = base + part
                let display = singleLine(control, width: widths[part])
                segments.append(
                    ScreenSegment(
                        text: TerminalText.fit(display.text, columns: widths[part]),
                        style: focused == control ? .menuSelection : .menu))
                hits.append(textHit(control, start: position, width: widths[part], offsets: display.offsets))
                if focused == control { cursorColumn = display.cursorColumn.map { position + $0 } }
                selectionColumns += display.selectionColumns.map {
                    (position + $0.lowerBound)..<(position + $0.upperBound)
                }
                position += widths[part]
            }
            rows.append(
                Row(
                    segments: segments, hits: hits, controls: [base, base + 1, base + 2],
                    containsCursor: (base..<(base + 3)).contains(focused), cursorColumn: cursorColumn,
                    selectionColumns: selectionColumns))
        }
        let focusedRow =
            rows.firstIndex { $0.controls.contains(focused) && $0.containsCursor }
            ?? rows.firstIndex { $0.controls.contains(focused) } ?? 0
        let capacity = panelHeight - 5
        let start = TerminalViewport.start(
            selected: focusedRow, count: rows.count, capacity: capacity,
            previous: form.scrollOffset ?? 0)
        self.form?.scrollOffset = start

        func popup(
            _ segments: [ScreenSegment], row: Int, hits: [MouseHit] = [], cursorColumn: Int? = nil,
            selectionColumns: [Range<Int>] = []
        ) {
            guard lines.indices.contains(row) else { return }
            let content = segments.map(\.text).joined()
            let used = cellWidth(content)
            let box =
                [ScreenSegment(text: "│", style: .menu)] + segments
                + [
                    ScreenSegment(
                        text: String(repeating: " ", count: max(0, inner - used)) + "│", style: .menu)
                ]
            let overlay = ScreenLine.popup(
                box.map(\.text).joined(), over: lines[row].text, column: x,
                boxWidth: panelWidth, width: width, style: .menu)
            let combined =
                [ScreenSegment(text: overlay.segments[0].text, style: .dimmed)]
                + box + [ScreenSegment(text: overlay.segments[2].text, style: .dimmed)]
            lines[row] = ScreenLine(
                text: combined.map(\.text).joined(), segments: combined, hits: hits,
                selectionColumns: selectionColumns.map { (x + 1 + $0.lowerBound)..<(x + 1 + $0.upperBound) },
                borderColumns: overlay.borderColumns, borderStyle: overlay.borderStyle,
                cursorColumn: cursorColumn.map { x + 1 + $0 })
        }
        func border(_ text: String, row: Int) {
            let overlay = ScreenLine.popup(
                text, over: lines[row].text, column: x, boxWidth: panelWidth,
                width: width, style: .menu)
            let segments = overlay.segments.enumerated().map {
                ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? .menu : .dimmed)
            }
            lines[row] = ScreenLine(
                text: overlay.text, segments: segments, borderColumns: overlay.borderColumns,
                borderStyle: overlay.borderStyle)
        }
        border("╭" + String(repeating: "─", count: inner) + "╮", row: y)
        popup(
            [
                ScreenSegment(
                    text: TerminalText.fit(
                        " View definition · "
                            + (definition.name.text.isEmpty ? "unnamed view" : definition.name.text),
                        columns: inner), style: .header)
            ], row: y + 1)
        for offset in 0..<capacity {
            let index = start + offset
            if rows.indices.contains(index) {
                popup(
                    rows[index].segments, row: y + 2 + offset, hits: rows[index].hits,
                    cursorColumn: rows[index].cursorColumn, selectionColumns: rows[index].selectionColumns)
            } else {
                popup([], row: y + 2 + offset)
            }
        }
        let scrollHint =
            rows.count > capacity ? " · \(start + 1)–\(min(rows.count, start + capacity))/\(rows.count)" : ""
        let hint =
            (focused >= 11
                ? " Alt-F5 Add · Alt-F6 Remove · Alt-F7 Earlier · Alt-F8 Later"
                : " Tab/Shift-Tab fields · Enter chooses")
            + scrollHint
        popup(
            [ScreenSegment(text: TerminalText.fit(hint, columns: inner), style: .dimmed)],
            row: y + panelHeight - 3)
        let actions = ScreenLine.controls(
            [("F8 Save", .save), ("F3 Save as", .saveAs), ("F9/Esc Cancel", .cancel)],
            style: .header)
        popup(
            [ScreenSegment(text: TerminalText.fit(actions.text, columns: inner), style: .header)],
            row: y + panelHeight - 2,
            hits: actions.hits.map {
                MouseHit(
                    columns: (x + 1 + $0.columns.lowerBound)..<(x + 1 + $0.columns.upperBound),
                    target: $0.target)
            })
        border("╰" + String(repeating: "─", count: inner) + "╯", row: y + panelHeight - 1)
        return OverlayRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    /// Category choices are a second, smaller overlay.  The definition panel intentionally stays
    /// underneath it so Apply/Cancel clearly affect only the originating category field.
    private func overlayViewDefinitionPicker(
        _ picker: Picker, on lines: inout [ScreenLine], width: Int, height: Int
    ) -> OverlayRect? {
        // While the selector is open, only its own controls can receive a mouse event.
        for index in lines.indices { lines[index].hits = [] }
        let usableHeight = max(1, height - 2)
        let boxWidth = min(width, max(24, min(viewFormGeometry().width - 4, 76)))
        let boxHeight = min(usableHeight, max(8, min(18, usableHeight - 8)))
        let x = max(0, (width - boxWidth) / 2)
        let y = max(0, (usableHeight - boxHeight) / 2)
        let inner = max(1, boxWidth - 2)
        func popup(
            _ text: String, row: Int, style: ScreenStyle, hits: [MouseHit] = [],
            selectionColumns: [Range<Int>] = []
        ) {
            guard lines.indices.contains(row) else { return }
            lines[row] = ScreenLine.popup(
                text, over: lines[row].text, column: x, boxWidth: boxWidth, width: width, style: style)
            if lines[row].segments.count == 3 {
                lines[row].segments = lines[row].segments.enumerated().map {
                    ScreenSegment(text: $0.element.text, style: $0.offset == 1 ? style : .dimmed)
                }
            }
            lines[row].hits = hits
            lines[row].selectionColumns = selectionColumns
        }
        let title: String
        switch picker.purpose {
        case .viewIncludedCategories: title = " Included categories"
        case .viewExcludedCategories: title = " Excluded categories"
        default: title = " Section categories"
        }
        popup("╭" + String(repeating: "─", count: inner) + "╮", row: y, style: .menu)
        popup(
            "│" + TerminalText.fit(title + " · Space toggle", columns: inner) + "│", row: y + 1,
            style: .header)
        let search = picker.filter.displayLines(columns: max(1, inner - 8), flatten: true).first!
        popup(
            "│" + TerminalText.fit(" Find: " + search.text, columns: inner) + "│", row: y + 2, style: .menu,
            hits: [MouseHit(columns: (x + 8)..<(x + boxWidth - 1), target: .pickerText(search.offsets))],
            selectionColumns: search.selectionColumns.map {
                (x + 8 + $0.lowerBound)..<(x + 8 + $0.upperBound)
            })
        let matches = picker.matches
        let capacity = max(1, boxHeight - 6)
        let start = TerminalViewport.start(
            selected: picker.index, count: matches.count, capacity: capacity,
            previous: picker.firstVisibleIndex)
        self.picker?.firstVisibleIndex = start
        for offset in 0..<capacity {
            let row = y + 3 + offset
            let index = start + offset
            if matches.indices.contains(index) {
                let item = matches[index]
                let selected = picker.selected.contains { $0.itemID == item.itemID }
                let key = pickerMouseKey(index)!
                popup(
                    "│"
                        + TerminalText.fit(
                            " \(index == picker.index ? ">" : " ") \(selected ? "[x]" : "[ ]") \(picker.title(item))",
                            columns: inner) + "│",
                    row: row, style: index == picker.index ? .menuSelection : .menu,
                    hits: [
                        MouseHit(columns: (x + 1)..<(x + boxWidth - 1), target: .pickerRow(index, key)),
                        MouseHit(
                            columns: (x + 4)..<min(x + boxWidth - 1, x + 8), target: .pickerToggle(index, key)
                        ),
                    ])
            } else {
                popup("│" + String(repeating: " ", count: inner) + "│", row: row, style: .menu)
            }
        }
        popup("│" + String(repeating: " ", count: inner) + "│", row: y + boxHeight - 3, style: .menu)
        let actions = ScreenLine.controls([("Ctrl-S Apply to form", .save), ("Esc Cancel", .cancel)])
        popup(
            "│" + TerminalText.fit(actions.text, columns: inner) + "│",
            row: y + boxHeight - 2,
            style: .header,
            hits: actions.hits.map {
                MouseHit(
                    columns: (x + 1 + $0.columns.lowerBound)..<(x + 1 + $0.columns.upperBound),
                    target: $0.target)
            })
        popup("╰" + String(repeating: "─", count: inner) + "╯", row: y + boxHeight - 1, style: .menu)
        return OverlayRect(x: x, y: y, width: boxWidth, height: boxHeight)
    }

    func render(columns: Int, rows: Int) -> [ScreenLine] {
        collectCategoryPreview()
        if mouseFrameSize.columns != columns || mouseFrameSize.rows != rows {
            mouse.cancel()
            // A smaller item panel must reveal its caret, rather than keep the old body's
            // first visible line with a now-shorter viewport.
            if let form, case .item = form.purpose { self.form?.scrollOffset = nil }
        }
        self.columns = columns
        self.rows = rows
        let categoryIsLoading =
            activeWorkspace == .categories && categoryWorkspace?.preview.status == .loading
        if !categoryIsLoading {
            let previewID = activePreviewItem?.itemID
            if activeWorkspace == .views {
                if viewPreviewItemID != previewID {
                    viewPreviewOffset = 0
                    viewPreviewItemID = previewID
                }
            } else if categoryPreviewItemID != previewID {
                categoryPreviewOffset = 0
                categoryPreviewItemID = previewID
            }
            scrollItemPreview(by: 0)
        }
        editorViewport = nil
        let width = max(1, columns - 1)
        let height = max(1, rows)
        let isViewDefinitionForm: Bool = {
            guard let form else { return false }
            if case .viewDefinition = form.purpose { return true }
            return false
        }()
        let isItemForm: Bool = {
            guard let form else { return false }
            if case .item = form.purpose { return true }
            return false
        }()
        let isAppearanceForm: Bool = {
            guard let form else { return false }
            switch form.purpose {
            case .appearance, .appearanceName: return true
            default: return false
            }
        }()
        let isCategoryPreferencesForm: Bool = {
            guard let form else { return false }
            if case .categoryPreferences = form.purpose { return true }
            return false
        }()
        let isCategoryDirtyForm: Bool = {
            guard let form else { return false }
            if case .categoryDirty = form.purpose { return true }
            return false
        }()
        let viewsTab = activeWorkspace == .views ? "[Views]" : "Views"
        let categoriesTab = activeWorkspace == .categories ? "[Categories]" : "Categories"
        let titlePrefix = " Tractanda · "
        let viewsStart = titlePrefix.count
        let categoriesStart = viewsStart + viewsTab.count + 3
        var lines = [
            ScreenLine(
                text: titlePrefix + viewsTab + " | " + categoriesTab
                    + " · \(activeWorkspace == .categories ? "Categories" : workspace.viewToUpdate?.fields["subject"]?.string ?? "Items")"
                    + (marks.items.isEmpty ? "" : " · ◆ \(marks.items.count) marked"),
                style: .title,
                hits: [
                    MouseHit(columns: 0..<min(12, width), target: .function(10)),
                    MouseHit(
                        columns: viewsStart..<min(width, viewsStart + viewsTab.count),
                        target: .command(.workspaceViews)),
                    MouseHit(
                        columns: categoriesStart..<min(width, categoriesStart + categoriesTab.count),
                        target: .command(.workspaceCategories)),
                ]
            )
        ]
        var viewSelectorRange: Range<Int>?
        if columns < 48 || rows < 12 {
            lines += [
                ScreenLine(text: "Enlarge terminal to at least 48 × 12."),
                ScreenLine(text: "Selection and draft are preserved."),
            ]
        } else if let panel {
            lines.append(ScreenLine(text: panel.title, style: .header))
            let wrapped = TerminalText.lines(panel.text, columns: width - 2)
            let offset = min(panelOffset, max(0, wrapped.count - (height - 5)))
            lines += wrapped.dropFirst(offset).prefix(height - 5).map { ScreenLine(text: " " + $0) }
        } else if let form, !isViewDefinitionForm, case .batch(let operation) = form.purpose {
            lines.append(ScreenLine(text: " \(form.title)", style: .header))
            let previewCount = max(1, height - 10)
            for entry in operation.entries.prefix(previewCount) {
                lines.append(ScreenLine(text: " · " + entry.title))
            }
            if operation.entries.count > previewCount {
                lines.append(
                    ScreenLine(
                        text: " … \(operation.entries.count - previewCount) more; B → V reviews all marks"))
            }
            lines.append(ScreenLine(text: " " + form.labels[0]))
            let display = form.fields[0].displayLines(
                columns: width - 3, cursorLayout: appearance.cursor.layout
            ).first!
            lines.append(
                ScreenLine(
                    text: " > " + display.text, style: .activeSelection,
                    hits: [MouseHit(columns: 3..<width, target: .fieldText(0, display.offsets))],
                    selectionColumns: display.selectionColumns.map {
                        (3 + $0.lowerBound)..<(3 + $0.upperBound)
                    },
                    cursorColumn: display.cursorColumn.map { 3 + $0 }))
            lines.append(.controls([("Ctrl-S confirm", .save), ("Esc cancel", .cancel)]))
        } else if let form, !isViewDefinitionForm, !isItemForm, !isAppearanceForm,
            !isCategoryPreferencesForm, !isCategoryDirtyForm
        {
            lines.append(ScreenLine(text: " \(form.title) · \(form.labels[form.focus])", style: .header))
            let submitLabel = viewDefinitionDraft == nil ? "Ctrl-S save" : "Ctrl-S apply"
            lines.append(
                .controls([(submitLabel, .save), ("Esc cancel", .cancel), ("Tab next field", .nextField)]))
            // Focused content uses the space left after one summary line for every other field.
            let available = max(2, height - form.fields.count - 6)
            for index in form.fields.indices {
                let label = "\(index == form.focus ? ">" : " ") \(form.labels[index]): "
                if index == form.focus {
                    lines.append(
                        ScreenLine(
                            text: label, style: .activeSelection,
                            hits: [MouseHit(columns: 0..<width, target: .field(index))]))
                    let content = form.fields[index].displayLines(
                        columns: width - 4, cursorLayout: appearance.cursor.layout)
                    let beforeCursor = content.firstIndex(where: \.containsCursor) ?? 0
                    let maximum = max(0, content.count - available)
                    let offset = min(maximum, max(0, form.scrollOffset ?? (beforeCursor - available + 1)))
                    editorViewport = (index, offset, maximum)
                    lines += content.dropFirst(offset).prefix(available).map {
                        ScreenLine(
                            text: "    " + $0.text,
                            hits: [MouseHit(columns: 4..<width, target: .fieldText(index, $0.offsets))],
                            selectionColumns: $0.selectionColumns.map {
                                (4 + $0.lowerBound)..<(4 + $0.upperBound)
                            },
                            cursorColumn: $0.cursorColumn.map { 4 + $0 })
                    }
                } else {
                    let x = min(width, label.reduce(0) { $0 + TerminalText.width($1) })
                    let display = form.fields[index].displayLines(
                        columns: max(1, width - x), marked: false, flatten: true
                    ).first!
                    lines.append(
                        ScreenLine(
                            text: label + display.text,
                            hits: [
                                MouseHit(columns: 0..<x, target: .field(index)),
                                MouseHit(columns: x..<width, target: .fieldText(index, display.offsets)),
                            ])
                    )
                }
            }
        } else if let learning {
            lines += LearningPresentation.lines(learning, width: width, height: height)
        } else if let picker, picker.purpose == .categories, let manager = categoryWorkspace {
            let presentation = CategoryWorkspacePresentation.render(
                manager: manager, rows: picker.treeRows, selectedIndex: picker.index,
                firstVisibleIndex: picker.firstVisibleIndex, filter: picker.filter,
                columns: categoryReportColumns,
                columnOffset: columnOffset, width: width, height: height,
                previewVisible: previewVisible && rows >= 24,
                previewContentRows: effectivePreviewContentRows,
                previewFocused: categoryPreviewFocused && isBottomPreviewVisible,
                previewOffset: categoryPreviewOffset,
                cursorLayout: appearance.cursor.layout,
                title: picker.title, rowKey: pickerMouseKey,
                categoriesWithChildren: picker.tree?.categoriesWithChildren ?? [])
            self.picker?.firstVisibleIndex = presentation.navigatorStart
            self.categoryWorkspace?.previewFirstVisible = presentation.previewStart
            self.categoryInspectorTextWidth = presentation.inspectorTextWidth
            categoryInspectorViewport = presentation.inspectorViewport
            lines += presentation.lines
        } else if let picker, !isViewDefinitionForm {
            let title: String
            switch picker.purpose {
            case .categories: title = "Category manager · Enter open · Meta-Return add filter · ←/→ tree"
            case .views: title = "Open saved view"
            case .sections: title = "Sections · Space/Enter toggle · Ctrl-S apply"
            case .viewIncludedCategories:
                title = "Included categories · Space/Enter toggle · Ctrl-S apply · maximum 32"
            case .viewExcludedCategories:
                title = "Excluded categories · Space/Enter toggle · Ctrl-S apply · maximum 32"
            case .include: title = "Include item in category (shared decision)"
            case .exclude: title = "Exclude item from category (shared decision)"
            case .reset: title = "Reset shared decision; personal overrides retain priority"
            case .explain: title = "Explain category assignment"
            case .history: title = "History · newest first · first 64 revisions"
            case .parent: title = "Move category under · Enter chooses parent · Esc cancels"
            case .learning: title = "Choose learning category · Enter opens · Esc cancels"
            case .completionCategory: title = "Choose completion category · Enter selects · Esc cancels"
            case .breadcrumb: title = "Category path · Enter opens prefix · Esc cancels"
            case .batchCategory:
                title = "\(batchAction?.title ?? "Group operation") · Choose category · Esc cancels"
            }
            lines.append(ScreenLine(text: title, style: .header))
            let search = picker.filter.displayLines(
                columns: max(1, width - 18), flatten: true, cursorLayout: appearance.cursor.layout
            ).first!
            let searchEnd = min(width - 11, 7 + search.text.reduce(0) { $0 + TerminalText.width($1) })
            lines.append(
                ScreenLine(
                    text: " Find: " + search.text + " · Esc back",
                    hits: [
                        MouseHit(columns: 7..<max(8, searchEnd), target: .pickerText(search.offsets)),
                        MouseHit(
                            columns: (searchEnd + 3)..<min(width, searchEnd + 11), target: .command(.cancel)),
                    ],
                    selectionColumns: search.selectionColumns.map {
                        (7 + $0.lowerBound)..<(7 + $0.upperBound)
                    },
                    cursorColumn: search.cursorColumn.map { 7 + $0 }))
            let matches = picker.matches
            let count = height - 6
            let start = TerminalViewport.start(
                selected: picker.index, count: matches.count, capacity: count,
                previous: picker.firstVisibleIndex)
            self.picker?.firstVisibleIndex = start
            if matches.isEmpty { lines.append(ScreenLine(text: " No matching entries.")) }
            for index in start..<min(matches.count, start + count) {
                let key = pickerMouseKey(index)!
                var hits = [MouseHit(columns: 0..<width, target: .pickerRow(index, key))]
                if picker.purpose == .sections || picker.purpose.isViewCategoryCriteria {
                    hits.append(MouseHit(columns: 3..<7, target: .pickerToggle(index, key)))
                }
                if picker.tree != nil, picker.treeRows[index].hasChildren {
                    let x =
                        3 + (picker.purpose == .sections ? 4 : 0) + (picker.treeRows[index].path.count - 1)
                        * 2
                    hits.append(MouseHit(columns: x..<(x + 2), target: .pickerDisclosure(index, key)))
                }
                lines.append(
                    ScreenLine(
                        text: " \(index == picker.index ? ">" : " ") "
                            + ((picker.purpose == .sections || picker.purpose.isViewCategoryCriteria)
                                ? (picker.selected.contains { $0.itemID == matches[index].itemID }
                                    ? "[x] " : "[ ] ") : "")
                            + (picker.tree == nil
                                ? ""
                                : String(repeating: "  ", count: picker.treeRows[index].path.count - 1)
                                    + (picker.treeRows[index].hasChildren
                                        ? (picker.treeRows[index].isExpanded ? "▾ " : "▸ ") : "  "))
                            + picker.title(matches[index]),
                        style: index == picker.index ? .activeSelection : .normal, hits: hits))
            }
        } else if let editor = columnEditor {
            lines.append(
                .controls(
                    [
                        ("N add", .addColumn), ("E edit", .editColumn),
                        ("X remove", .deleteColumn), ("← move", .moveLeft), ("→ move", .moveRight),
                    ], prefix: "Columns", style: .header))
            lines.append(.controls([("Ctrl-S apply layout", .save), ("Esc cancel", .cancel)]))
            let start = TerminalViewport.start(
                selected: editor.index, count: editor.columns.count, capacity: height - 6,
                previous: firstVisibleColumn)
            firstVisibleColumn = start
            for index in start..<min(editor.columns.count, start + height - 6) {
                let column = editor.columns[index]
                lines.append(
                    ScreenLine(
                        text:
                            " \(index == editor.index ? ">" : " ") \(column.title) · \(columnTarget(column)) · width \(column.width)",
                        style: index == editor.index ? .activeSelection : .normal,
                        hits: [MouseHit(columns: 0..<width, target: .columnRow(index, columnTarget(column)))])
                )
            }
        } else if isBatchMenuOpen {
            lines.append(ScreenLine(text: " Group operations · \(marks.items.count) marked", style: .header))
            lines += [
                ("V  Review marked items", TUICommand.reviewMarks), ("I  Assign to category", .include),
                ("X  Exclude from category", .exclude), ("U  Reset shared category decision", .reset),
                ("D  Mark done", .done), ("Del  Delete items (history retained)", .deleteItems),
                ("Esc  Cancel", .cancel),
            ].map { .controls([$0]) }
            lines.append(ScreenLine(text: " Each operation shows a confirmation before writing."))
        } else {
            let sideBySide = viewSelectorVisible && width >= 79 && height >= 24
            let selectorWidth = max(
                22, min(width - 28, Int(Double(width) * viewPreferences.selectorSplitWidth)))
            let reportWidth = sideBySide ? width - selectorWidth - 1 : width
            let reportIsPassive =
                (viewSelectorVisible && viewWorkspaceFocused)
                || (viewPreviewFocused && isBottomPreviewVisible)
            let reportStyle: ScreenStyle = reportIsPassive ? .dimmed : .normal
            let reportHeaderStyle: ScreenStyle = reportIsPassive ? .dimmed : .header
            if viewSelectorVisible, let selector = viewWorkspace {
                let selectorStart = lines.count
                let compactSplit = height < 24
                let selectorStyle: ScreenStyle = viewWorkspaceFocused ? .normal : .dimmed
                let selectorHeaderStyle: ScreenStyle = viewWorkspaceFocused ? .header : .dimmed
                let selectorSelectionStyle: ScreenStyle =
                    viewWorkspaceFocused ? .activeSelection : .inactiveSelection
                let filter = selector.filter.displayLines(
                    columns: max(1, sideBySide ? selectorWidth - 8 : width - 22), flatten: true,
                    cursorLayout: appearance.cursor.layout
                ).first!
                let selectedName: String
                if selector.index < 0 {
                    selectedName = "All items"
                } else if selector.matches.indices.contains(selector.index) {
                    selectedName = selector.title(selector.matches[selector.index])
                } else {
                    selectedName = "All items"
                }
                lines.append(
                    .controls(
                        [
                            (viewWorkspaceFocused ? "F8 focus items" : "F8 focus views", .toggleSelector),
                            ("F2/Ctrl-E edit", .editView),
                            ("Ctrl-N new", .newView), ("Meta-M pin", .pinView),
                        ],
                        prefix: "Views · " + (viewWorkspaceFocused ? "focused" : "report focused"),
                        style: selectorHeaderStyle))
                lines.append(
                    ScreenLine(
                        text: " Find: " + filter.text + " · Tab report · selected: " + selectedName,
                        style: selectorStyle,
                        hits: [
                            MouseHit(
                                columns: 7..<min(width, 7 + max(1, filter.text.count)),
                                target: .viewWorkspaceText(filter.offsets))
                        ],
                        selectionColumns: filter.selectionColumns.map {
                            (7 + $0.lowerBound)..<(7 + $0.upperBound)
                        },
                        cursorColumn: viewWorkspaceFocused ? filter.cursorColumn.map { 7 + $0 } : nil))
                if compactSplit {
                    if selector.matches.indices.contains(selector.index) {
                        let selected = selector.matches[selector.index]
                        let pin = viewPreferences.pinnedViewIDs.contains(selected.itemID) ? "★ " : "  "
                        let key = viewWorkspaceMouseKey(selector.index)!
                        lines.append(
                            ScreenLine(
                                text: " > " + pin + selector.title(selected) + " · All items available",
                                style: selectorSelectionStyle,
                                hits: [
                                    MouseHit(
                                        columns: 0..<width,
                                        target: .viewWorkspaceRow(selector.index, key))
                                ]))
                    } else {
                        lines.append(
                            ScreenLine(
                                text: " > All items · implicit universal view",
                                style: selectorSelectionStyle,
                                hits: [MouseHit(columns: 0..<width, target: .viewWorkspaceAllItems)]))
                    }
                } else {
                    let available =
                        sideBySide
                        ? max(1, height - (previewVisible ? effectivePreviewContentRows + 1 : 0) - 7)
                        : max(1, min(4, height / 4))
                    let start = TerminalViewport.start(
                        selected: max(0, selector.index), count: selector.matches.count, capacity: available,
                        previous: selector.firstVisibleIndex)
                    viewWorkspace?.firstVisibleIndex = start
                    if selector.filter.text.isEmpty {
                        lines.append(
                            ScreenLine(
                                text: " " + (selector.index < 0 ? ">" : " ")
                                    + "   All items · implicit universal view",
                                style: selector.index < 0 ? selectorSelectionStyle : selectorStyle,
                                hits: [MouseHit(columns: 0..<width, target: .viewWorkspaceAllItems)]))
                    }
                    for index in start..<min(selector.matches.count, start + available) {
                        let view = selector.matches[index]
                        let pin = viewPreferences.pinnedViewIDs.contains(view.itemID) ? "★ " : "  "
                        let key = viewWorkspaceMouseKey(index)!
                        lines.append(
                            ScreenLine(
                                text: " " + (index == selector.index ? ">" : " ") + " " + pin
                                    + selector.title(view),
                                style: index == selector.index ? selectorSelectionStyle : selectorStyle,
                                hits: [MouseHit(columns: 0..<width, target: .viewWorkspaceRow(index, key))]))
                    }
                    if selector.matches.isEmpty {
                        lines.append(
                            ScreenLine(
                                text: selector.filter.text.isEmpty
                                    ? " No saved views yet. Ctrl-N creates one; All items remains available."
                                    : " No matching saved views. Clear Find to browse the catalog.",
                                style: selectorStyle))
                    }
                    lines.append(
                        ScreenLine(
                            text: " ─────────────────────────────────────────────────────────────",
                            style: selectorStyle))
                }
                viewSelectorRange = selectorStart..<lines.count
            }
            lines.append(
                Breadcrumbs.line(
                    path: workspace.categoryPath, width: reportWidth,
                    categoriesWithChildren: workspace.categoriesWithChildren))
            lines.append(
                ScreenLine(
                    text:
                        " \(workspace.total) \(workspace.sectionCategories.isEmpty ? "items" : "section entries") · \(workspace.expression.isEmpty ? "No expression filter" : workspace.expression)\(workspace.text.isEmpty ? "" : " · text: " + workspace.text)",
                    style: reportStyle
                ))
            // Both primary workspaces reserve a full-width bottom preview. Compact terminals hide
            // it without changing selection or query state.
            let reservedPreviewRows =
                previewVisible && !isCompactViewWorkspace ? effectivePreviewContentRows + 1 : 0
            let selectorRows = sideBySide ? (viewSelectorRange?.count ?? 0) : 0
            let count = max(1, height - lines.count + selectorRows - 3 - reservedPreviewRows)
            renderedReportPageHeight = count
            let browserRows = workspace.rows
            itemIndex = min(itemIndex, max(0, browserRows.count - 1))
            if !workspace.excludedCategoryNames.isEmpty, lines.indices.contains(2) {
                lines[2].text += " · excluding: " + workspace.excludedCategoryNames.joined(separator: ", ")
            }
            columnOffset = min(columnOffset, workspace.columns.count - 1)
            let start = TerminalViewport.start(
                selected: itemIndex, count: browserRows.count, capacity: count, previous: firstVisibleItem)
            firstVisibleItem = start
            let left = reportWidth
            lines.append(
                ScreenLine(
                    text: "  "
                        + TableLayout.line(
                            item: nil, columns: workspace.columns,
                            offset: columnOffset, width: left - 2),
                    style: reportHeaderStyle))
            for row in 0..<count {
                let index = start + row
                var text = ""
                var hits: [MouseHit] = []
                if browserRows.indices.contains(index) {
                    let entry = browserRows[index]
                    let section = workspace.sections[entry.sectionIndex]
                    let key = browserMouseKey(index)!
                    hits.append(MouseHit(columns: 0..<left, target: .browserRow(index, key)))
                    text = index == itemIndex ? "> " : "  "
                    switch entry.content {
                    case .item(let item):
                        hits.append(MouseHit(columns: 2..<4, target: .browserMark(index, key)))
                        text += marks.contains(item.itemID) ? "◆ " : "  "
                        text += TableLayout.line(
                            item: item, columns: workspace.columns, offset: columnOffset, width: left - 4,
                            preferredScopes: workspace.categoryPath.map(\.itemID),
                            categoryMemberships: workspace.categoryMemberships,
                            categoryLabels: workspace.categoryMembershipLabels)
                    case .heading:
                        hits.append(MouseHit(columns: 2..<5, target: .browserDisclosure(index, key)))
                        let category = section.category!
                        text +=
                            "\(workspace.collapsedSectionIDs.contains(category.itemID) ? "[+]" : "[-]") \(category.fields["subject"]?.string ?? "Category") · \(section.total) items"
                    case .previousPage: text += "Previous page · Enter (before \(section.position + 1))"
                    case .nextPage:
                        text +=
                            "Next page · Enter (\(section.position + section.items.count) of \(section.total))"
                    }
                } else if browserRows.isEmpty, row == 0 {
                    text = " No items. N creates one; C opens categories; A clears filters."
                }
                let isSelected = index == itemIndex && browserRows.indices.contains(index)
                let rowStyle: ScreenStyle =
                    isSelected
                    ? (reportIsPassive ? .inactiveSelection : .activeSelection) : reportStyle
                lines.append(ScreenLine(text: text, style: rowStyle, hits: hits))
            }
            if previewVisible && !isCompactViewWorkspace {
                lines += ItemPreviewPresentation.lines(
                    item: current, width: width, offset: viewPreviewOffset, focused: viewPreviewFocused,
                    contentRows: effectivePreviewContentRows)
            }
        }
        // On normal terminals Views uses the same selector-left, items-right, full-width-preview
        // geometry as Categories. The existing lines retain their state and hit targets; projection
        // only changes their placement.
        if let selectorRange = viewSelectorRange, width >= 79, height >= 24,
            selectorRange.lowerBound > 0, selectorRange.upperBound <= lines.count
        {
            let selector = Array(lines[selectorRange])
            var report = Array(lines[selectorRange.upperBound...])
            let previewCount =
                previewVisible && !isCompactViewWorkspace
                ? min(effectivePreviewContentRows + 1, report.count) : 0
            let preview = previewCount == 0 ? [] : Array(report.suffix(previewCount))
            if previewCount > 0 { report.removeLast(previewCount) }
            let leftWidth = max(22, min(width - 28, Int(Double(width) * viewPreferences.selectorSplitWidth)))
            let rightWidth = max(1, width - leftWidth - 1)
            func shifted(_ hits: [MouseHit], width: Int, offset: Int) -> [MouseHit] {
                hits.compactMap { hit in
                    let lower = max(0, hit.columns.lowerBound)
                    let upper = min(width, hit.columns.upperBound)
                    guard lower < upper else { return nil }
                    return MouseHit(columns: (offset + lower)..<(offset + upper), target: hit.target)
                }
            }
            var combined = [lines[0]]
            let count = max(selector.count, report.count)
            for index in 0..<count {
                let left = index < selector.count ? selector[index] : ScreenLine(text: "", style: .dimmed)
                let right = index < report.count ? report[index] : ScreenLine(text: "", style: .normal)
                let a = TerminalText.fit(left.text, columns: leftWidth)
                let b = TerminalText.fit(right.text, columns: rightWidth)
                combined.append(
                    ScreenLine(
                        text: a + "│" + b,
                        segments: [
                            ScreenSegment(text: a, style: left.style),
                            ScreenSegment(text: "│", style: .dimmed),
                        ]
                            + (right.segments.isEmpty
                                ? [ScreenSegment(text: b, style: right.style)] : right.segments),
                        hits: shifted(left.hits, width: leftWidth, offset: 0)
                            + [MouseHit(columns: leftWidth..<(leftWidth + 1), target: .viewDivider)]
                            + shifted(right.hits, width: rightWidth, offset: leftWidth + 1),
                        selectionColumns: left.selectionColumns.compactMap {
                            let lower = max(0, $0.lowerBound)
                            let upper = min(leftWidth, $0.upperBound)
                            return lower < upper ? lower..<upper : nil
                        },
                        cursorColumn: viewWorkspaceFocused
                            ? left.cursorColumn : right.cursorColumn.map { leftWidth + 1 + $0 }))
            }
            combined += preview
            lines = combined
        }
        // Help, error panels and the undersized-terminal safeguard take precedence over the modal.
        let showsViewDefinitionOverlay = isViewDefinitionForm && panel == nil && columns >= 48 && rows >= 12
        lines = Array(lines.prefix(max(1, height - 2)))
        let blankBodyStyle: ScreenStyle =
            viewSelectorVisible && viewWorkspaceFocused ? .dimmed : .activePane
        while lines.count < height - 2 { lines.append(ScreenLine(text: "", style: blankBodyStyle)) }
        // Body content has its own active-pane role.  Status and function-key chrome are appended
        // below, so changing a palette cannot spill into those distinct styles.
        for index in lines.indices {
            if lines[index].style == .normal { lines[index].style = .activePane }
            lines[index].segments = lines[index].segments.map {
                ScreenSegment(text: $0.text, style: $0.style == .normal ? .activePane : $0.style)
            }
        }
        var overlayRects: [OverlayRect] = []
        if showsViewDefinitionOverlay {
            if let rect = overlayViewDefinitionForm(on: &lines, width: width, height: height) {
                overlayRects.append(rect)
            }
            if let picker,
                let rect = overlayViewDefinitionPicker(picker, on: &lines, width: width, height: height)
            {
                overlayRects.append(rect)
            }
        }
        if isItemForm && panel == nil && columns >= 48 && rows >= 12,
            let rect = overlayItemForm(on: &lines, width: width, height: height)
        {
            overlayRects.append(rect)
        }
        if panel == nil && columns >= 48 && rows >= 12,
            let rect = overlayCategoryDirty(on: &lines, width: width, height: height)
        {
            overlayRects.append(rect)
        }
        if isAppearanceForm && panel == nil && columns >= 48 && rows >= 12 {
            if let rect = overlayAppearanceForm(on: &lines, width: width, height: height) {
                overlayRects.append(rect)
            }
            if let rect = overlayAppearanceName(on: &lines, width: width, height: height) {
                overlayRects.append(rect)
            }
        }
        if isCategoryPreferencesForm && panel == nil && columns >= 48 && rows >= 12,
            let rect = overlayCategoryPreferences(on: &lines, width: width, height: height)
        {
            overlayRects.append(rect)
        }
        if height > 1 {
            let prefix = keyContext == .browser ? " A All · " : " "
            lines.append(
                ScreenLine(
                    text: prefix + status,
                    hits: keyContext == .browser
                        ? [MouseHit(columns: 1..<10, target: .command(.allItems))] : []))
        }
        if height > 2 {
            lines.append(
                functionBar(
                    context: keyContext, width: width,
                    previewFocused: isBottomPreviewVisible && activePreviewFocused))
        }
        if let menu, panel == nil, columns >= 48, rows >= 12,
            let rect = overlayMenu(menu, on: &lines, width: width, height: height)
        {
            overlayRects.append(rect)
        }
        if let childMenu, panel == nil, columns >= 48, rows >= 12,
            let rect = overlayChildMenu(childMenu, on: &lines, width: width, height: height)
        {
            overlayRects.append(rect)
        }
        applyDropShadows(overlayRects, to: &lines, width: width, height: height)
        let result = Array(lines.prefix(height))
        mouseLines = result
        mouseFrameSize = (columns, rows)
        mouseFrameScene = mouseScene
        return result
    }
}
