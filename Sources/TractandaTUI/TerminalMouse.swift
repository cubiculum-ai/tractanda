import Foundation

/// Cell coordinates are zero-based within the currently displayed terminal frame.
struct TerminalMouseEvent: Equatable, Sendable {
    enum Button: Int, Sendable {
        case left = 0
        case middle, right, none
    }
    enum Kind: Equatable, Sendable {
        case press, release, drag, hover, scrollUp, scrollDown, scrollLeft, scrollRight
    }
    let kind: Kind
    let button: Button
    let column: Int
    let row: Int
    let modifiers: KeyModifiers

    static func decode(code: Int, x: Int, y: Int, release: Bool, legacy: Bool = false) -> TerminalKey {
        guard (0...127).contains(code), (1...1_000_000).contains(x), (1...1_000_000).contains(y) else {
            return .ignored
        }
        let button = Button(rawValue: code & 3)!
        var modifiers: KeyModifiers = []
        if code & 4 != 0 { modifiers.insert(.shift) }
        if code & 8 != 0 { modifiers.insert(.option) }
        if code & 16 != 0 { modifiers.insert(.control) }
        let kind: Kind
        if code & 64 != 0 {
            guard !release, code & 32 == 0 else { return .ignored }
            kind = [.scrollUp, .scrollDown, .scrollLeft, .scrollRight][code & 3]
        } else if code & 32 != 0 {
            guard !release else { return .ignored }
            kind = button == .none ? .hover : .drag
        } else if release || (legacy && button == .none) {
            kind = .release
        } else {
            guard button != .none else { return .ignored }
            kind = .press
        }
        return .mouse(Self(kind: kind, button: button, column: x - 1, row: y - 1, modifiers: modifiers))
    }
}

enum TerminalMouseReporting {
    // Tracking and encodings are mutually exclusive. Save only modes we change.
    private static let modes = "9;1000;1001;1002;1003;1005;1006;1015;1016"
    static let save = "\u{1b}[?\(modes)s"
    static let disable = "\u{1b}[?\(modes)l"
    static let restore = disable + "\u{1b}[?\(modes)r"
    static func configure(enabled: Bool, hover: Bool = false) -> String {
        disable + (enabled ? "\u{1b}[?1006h\u{1b}[?\(hover ? 1003 : 1002)h" : "")
    }
}

/// Targets are attached while rendering, so mouse geometry follows the actual visible layout.
enum MouseTarget: Equatable {
    case command(TUICommand)
    case function(Int)
    case breadcrumb(Int, [String])
    case breadcrumbChooser([String])
    /// A nil parent index opens the readable roots from All items.
    case breadcrumbChildren(Int?, [String])
    case categoryBreadcrumb(Int, [String])
    case categoryBreadcrumbChooser([String])
    case categoryBreadcrumbChildren(Int?, [String])
    case childCategory(Int, String)
    case browserRow(Int, String)
    case browserMark(Int, String)
    case browserDisclosure(Int, String)
    case pickerRow(Int, String)
    case categoryAllItems
    case categoryModeItems
    case categoryModeInspector
    case categoryPreviewPrevious
    case categoryPreviewNext
    case categoryDirtyDiscard
    case categoryDivider
    case viewDivider
    case categoryInspectorText(Int, [Int])
    case categoryPreviewRow(Int, String)
    case itemPreview
    case previewDivider
    case categoryToggleTree
    case categoryToggleMaximize
    case pickerDisclosure(Int, String)
    case pickerToggle(Int, String)
    case viewWorkspaceRow(Int, String)
    case viewWorkspaceAllItems
    case viewWorkspaceText([Int])
    case viewDefinitionControl(Int)
    case viewDefinitionText(Int, [Int])
    case learningRow(Int, String)
    case columnRow(Int, String)
    case menuGroup(Int)
    case menuCommand(TUICommand)
    case menuStep(Int)
    case menuSurface
    case field(Int)
    case fieldText(Int, [Int])
    case pickerText([Int])
}

struct MouseHit: Equatable {
    let columns: Range<Int>
    let target: MouseTarget
}

enum TerminalViewport {
    static func start(selected: Int, count: Int, capacity: Int, previous: Int) -> Int {
        let capacity = max(1, capacity)
        var start = min(max(0, previous), max(0, count - capacity))
        if selected < start { start = selected }
        if selected >= start + capacity { start = selected - capacity + 1 }
        return max(0, start)
    }
}

/// Gestures never outlive a resize, a keyboard action, or a change of interaction context.
struct MouseGesture {
    struct Press {
        let target: MouseTarget
        let scene: String
        let column: Int
        let row: Int
        var dragged = false
    }
    var press: Press?
    var lastClick: (target: MouseTarget, scene: String, time: TimeInterval)?
    mutating func cancel() {
        press = nil
        lastClick = nil
    }

    mutating func isDoubleClick(_ target: MouseTarget, scene: String, at time: TimeInterval) -> Bool {
        if let previous = lastClick, previous.target == target, previous.scene == scene,
            (0...0.45).contains(time - previous.time)
        {
            lastClick = nil
            return true
        }
        lastClick = (target, scene, time)
        return false
    }
}
