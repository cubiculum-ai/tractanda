import CTractandaPlatform
import Foundation
import TractandaCore

/// A terminal color is either one of the portable ANSI palette values or a CSS-like RGB literal.
/// Keeping the encoded form as a string preserves the version-one appearance JSON unchanged.
struct AppearanceColor: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        let normalized = rawValue == "default" ? rawValue : rawValue.lowercased()
        guard Self.namedCodes[normalized] != nil || Self.rgb(normalized) != nil else { return nil }
        self.rawValue = normalized
    }

    private init(_ rawValue: String) { self.rawValue = rawValue }

    static let `default` = AppearanceColor("default")
    static let black = AppearanceColor("black")
    static let red = AppearanceColor("red")
    static let green = AppearanceColor("green")
    static let yellow = AppearanceColor("yellow")
    static let blue = AppearanceColor("blue")
    static let magenta = AppearanceColor("magenta")
    static let cyan = AppearanceColor("cyan")
    static let white = AppearanceColor("white")
    static let brightBlack = AppearanceColor("brightblack")
    static let brightRed = AppearanceColor("brightred")
    static let brightGreen = AppearanceColor("brightgreen")
    static let brightYellow = AppearanceColor("brightyellow")
    static let brightBlue = AppearanceColor("brightblue")
    static let brightMagenta = AppearanceColor("brightmagenta")
    static let brightCyan = AppearanceColor("brightcyan")
    static let brightWhite = AppearanceColor("brightwhite")
    static let allCases: [AppearanceColor] = [
        .default, .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white,
        .brightBlack, .brightRed, .brightGreen, .brightYellow, .brightBlue, .brightMagenta,
        .brightCyan, .brightWhite,
    ]

    private static let namedCodes: [String: Int] = [
        "default": 39, "black": 30, "red": 31, "green": 32, "yellow": 33, "blue": 34,
        "magenta": 35, "cyan": 36, "white": 37, "brightblack": 90, "brightred": 91,
        "brightgreen": 92, "brightyellow": 93, "brightblue": 94, "brightmagenta": 95,
        "brightcyan": 96, "brightwhite": 97,
    ]

    private static func rgb(_ value: String) -> (Int, Int, Int)? {
        guard value.utf8.count == 7, value.first == "#",
            value.dropFirst().allSatisfy({ $0.isHexDigit }),
            let packed = Int(value.dropFirst(), radix: 16)
        else { return nil }
        return ((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF)
    }

    var foregroundCodes: [String] {
        if let code = Self.namedCodes[rawValue.lowercased()] { return [String(code)] }
        if let (red, green, blue) = Self.rgb(rawValue) {
            return ["38", "2", String(red), String(green), String(blue)]
        }
        return ["39"]
    }

    var backgroundCodes: [String] {
        if let code = Self.namedCodes[rawValue.lowercased()] {
            return [String(code == 39 ? 49 : code + 10)]
        }
        if let (red, green, blue) = Self.rgb(rawValue) {
            return ["48", "2", String(red), String(green), String(blue)]
        }
        return ["49"]
    }

    /// OSC 12 accepts XParseColor values, not portable ANSI palette names.
    var cursorOSCValue: String {
        if rawValue.hasPrefix("#") { return rawValue }
        return Self.cursorPalette[rawValue.lowercased()] ?? "#ffffff"
    }

    private static let cursorPalette: [String: String] = [
        "black": "#000000", "red": "#cc0000", "green": "#4e9a06", "yellow": "#c4a000",
        "blue": "#3465a4", "magenta": "#75507b", "cyan": "#06989a", "white": "#d3d7cf",
        "brightblack": "#555753", "brightred": "#ef2929", "brightgreen": "#8ae234",
        "brightyellow": "#fce94f", "brightblue": "#729fcf", "brightmagenta": "#ad7fa8",
        "brightcyan": "#34e2e2", "brightwhite": "#eeeeec",
    ]

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(), debugDescription: "Invalid terminal color")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum CursorLayout: String, CaseIterable, Codable, Sendable { case gap, native }
enum CursorShape: String, CaseIterable, Codable, Sendable {
    case block, underline, beam
    var decscusr: Int { self == .block ? 2 : self == .underline ? 4 : 6 }
}

struct CursorPreferences: Codable, Equatable, Sendable {
    var layout: CursorLayout = .gap
    var shape: CursorShape = .beam
    var color: AppearanceColor = .default
    var blink = false
}

/// DEC cursor style and xterm OSC 12 are best-effort capabilities.  We never alter a terminal
/// preference permanently: reset is used when no query response was available.
enum TerminalCursorProtocol {
    struct Snapshot: Equatable {
        var style: Int?
        var color: String?
    }

    static let query = "\u{1b}P$q q\u{1b}\\\u{1b}]12;?\u{07}"

    static func apply(_ value: CursorPreferences, capturedColor: String? = nil) -> String {
        let style = value.shape.decscusr - (value.blink ? 1 : 0)
        let color: String
        if value.color == .default {
            // Keep the terminal's active color untouched until a bounded startup query tells us
            // what to replay.  The exit path still resets to the terminal default if unsupported.
            color = capturedColor.map { "\u{1b}]12;\($0)\u{07}" } ?? ""
        } else {
            color = "\u{1b}]12;\(value.color.cursorOSCValue)\u{07}"
        }
        return "\u{1b}[\(style) q" + color
    }

    static func restore(style: Int?, color: String?) -> String {
        let cursorStyle = style.map { "\u{1b}[\($0) q" } ?? "\u{1b}[0 q"
        let cursorColor = color.map { "\u{1b}]12;\($0)\u{07}" } ?? "\u{1b}]112\u{07}"
        return cursorStyle + cursorColor
    }

    static func parse(_ reply: String) -> Snapshot {
        // DECRQSS: DCS 1 $ r Ps SP q ST.  OSC 12 returns rgb:rrrr/gggg/bbbb.
        if reply.hasPrefix("\u{1b}P1$r"), reply.hasSuffix(" q\u{1b}\\") {
            let body = reply.dropFirst(5).dropLast(4)
            return Snapshot(style: Int(body).flatMap { (0...6).contains($0) ? $0 : nil }, color: nil)
        }
        if reply.hasPrefix("\u{1b}]12;") {
            let body = reply.dropFirst(5).dropLast(reply.hasSuffix("\u{1b}\\") ? 2 : 1)
            let color = String(body)
            return Snapshot(style: nil, color: isTerminalColorReply(color) ? color : nil)
        }
        return Snapshot(style: nil, color: nil)
    }

    private static func isTerminalColorReply(_ value: String) -> Bool {
        if value.utf8.count == 7, value.first == "#", value.dropFirst().allSatisfy(\.isHexDigit) {
            return true
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("rgb:") else { return false }
        return parts[0].dropFirst(4).count <= 4 && !parts[0].dropFirst(4).isEmpty
            && parts.allSatisfy { part in
                let digits = part.hasPrefix("rgb:") ? part.dropFirst(4) : part[...]
                return !digits.isEmpty && digits.count <= 4 && digits.allSatisfy(\.isHexDigit)
            }
    }
}

enum AppearanceRole: String, CaseIterable, Codable, Sendable {
    case activeSelection, inactiveSelection, titleBar, heading, functionKeyNumber, functionKeyLabel
    case menuSurface, menuSelection, activePane, passivePane

    static let activePaneDefault = AppearancePair(foreground: .default, background: .default)

    var title: String {
        switch self {
        case .activeSelection: "Active selection"
        case .inactiveSelection: "Inactive selection"
        case .titleBar: "Title bars"
        case .heading: "Table and section headings"
        case .functionKeyNumber: "Function-key number"
        case .functionKeyLabel: "Function-key label"
        case .menuSurface: "Menu surface"
        case .menuSelection: "Menu selection"
        case .activePane: "Active pane"
        case .passivePane: "Passive pane"
        }
    }
}

struct AppearancePair: Codable, Equatable, Sendable {
    var foreground: AppearanceColor
    var background: AppearanceColor
    var bold = false
    var dim = false

    private enum CodingKeys: String, CodingKey { case foreground, background, bold, dim }
    init(foreground: AppearanceColor, background: AppearanceColor, bold: Bool = false, dim: Bool = false) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try values.decode(AppearanceColor.self, forKey: .foreground)
        background = try values.decode(AppearanceColor.self, forKey: .background)
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        dim = try values.decodeIfPresent(Bool.self, forKey: .dim) ?? false
    }
}

struct AppearancePalette: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var roles: [AppearanceRole: AppearancePair]

    private enum CodingKeys: String, CodingKey { case id, name, roles }
    init(id: String, name: String, roles: [AppearanceRole: AppearancePair]) {
        self.id = id
        self.name = name
        self.roles = roles
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        let rawRoles = try values.decode([String: AppearancePair].self, forKey: .roles)
        var parsed: [AppearanceRole: AppearancePair] = [:]
        for (key, value) in rawRoles {
            guard let role = AppearanceRole(rawValue: key), parsed[role] == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .roles, in: values, debugDescription: "Invalid appearance role")
            }
            parsed[role] = value
        }
        // Version-four added this role.  It is the only omission accepted from an older palette;
        // all other missing or malformed roles still fail normal completeness validation.
        if parsed[.activePane] == nil { parsed[.activePane] = AppearanceRole.activePaneDefault }
        roles = parsed
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(
            Dictionary(uniqueKeysWithValues: roles.map { ($0.key.rawValue, $0.value) }), forKey: .roles)
    }
}

private struct ShippedAppearancePalettes: Codable {
    let defaultPresetID: String
    let palettes: [AppearancePalette]
}

/// The stored selection is deliberately an ID, not a closed set of Swift cases.  `custom` is
/// reserved for the retained, user-edited color roles; all ordinary palettes are data records.
struct TerminalAppearance: Codable, Equatable, Sendable {
    static let customPresetID = "custom"
    static let maximumSavedPalettes = 16
    private static let maximumBytes = 131_072

    var version = 4
    var preset: String
    var roles: [AppearanceRole: AppearancePair]
    var cursor: CursorPreferences
    /// Effects are independent of color presets, like cursor preferences.
    var showsDropShadows = false
    var customRoles: [AppearanceRole: AppearancePair]?
    var savedPalettes: [AppearancePalette]

    private enum CodingKeys: String, CodingKey {
        case version, preset, roles, cursor, showsDropShadows, customRoles, savedPalettes
    }

    /// A deliberately small fallback used only if the packaged JSON cannot be loaded.  The
    /// actual initial Blue and Amber choices are resource data, not special engine cases.
    static let blueFallbackRoles: [AppearanceRole: AppearancePair] = [
        .activeSelection: .init(foreground: .brightWhite, background: .blue),
        .inactiveSelection: .init(foreground: .white, background: .blue, dim: true),
        .titleBar: .init(foreground: .brightWhite, background: .blue),
        .heading: .init(foreground: .default, background: .default, bold: true),
        .functionKeyNumber: .init(foreground: .brightWhite, background: .blue),
        .functionKeyLabel: .init(foreground: .black, background: .white),
        .menuSurface: .init(foreground: .black, background: .white),
        .menuSelection: .init(foreground: .brightWhite, background: .blue),
        .activePane: AppearanceRole.activePaneDefault,
        .passivePane: .init(foreground: .default, background: .default, dim: true),
    ]
    private static let fallbackLibrary = ShippedAppearancePalettes(
        defaultPresetID: "blue",
        palettes: [.init(id: "blue", name: "Blue", roles: blueFallbackRoles)])

    private static let shippedPalettes: ShippedAppearancePalettes = {
        guard let url = Bundle.module.url(forResource: "AppearancePresets", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let value = try? JSONDecoder().decode(ShippedAppearancePalettes.self, from: data),
            validLibrary(value.palettes), value.palettes.contains(where: { $0.id == value.defaultPresetID })
        else { return fallbackLibrary }
        return value
    }()

    init(
        version: Int = 4, preset: String? = nil, roles: [AppearanceRole: AppearancePair]? = nil,
        cursor: CursorPreferences = .init(), showsDropShadows: Bool = false,
        customRoles: [AppearanceRole: AppearancePair]? = nil,
        savedPalettes: [AppearancePalette]? = nil
    ) {
        let library = savedPalettes ?? Self.shippedPalettes.palettes
        let selected = preset ?? Self.shippedPalettes.defaultPresetID
        let displayed = roles ?? library.first(where: { $0.id == selected })?.roles ?? Self.blueFallbackRoles
        self.version = version
        self.preset = selected
        self.roles = Self.migratingActivePane(displayed)
        self.cursor = cursor
        self.showsDropShadows = showsDropShadows
        self.customRoles =
            customRoles.map(Self.migratingActivePane)
            ?? (selected == Self.customPresetID ? Self.migratingActivePane(displayed) : nil)
        self.savedPalettes = library
    }

    static func initial() -> TerminalAppearance { TerminalAppearance() }

    static func preset(_ id: String) -> TerminalAppearance {
        let library = shippedPalettes.palettes
        let selected = library.first(where: { $0.id == id })?.id ?? shippedPalettes.defaultPresetID
        return TerminalAppearance(preset: selected, savedPalettes: library)
    }

    func palette(namedOrID value: String) -> AppearancePalette? {
        savedPalettes.first {
            $0.id.caseInsensitiveCompare(value) == .orderedSame
                || $0.name.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    var presetDisplayName: String {
        preset == Self.customPresetID ? "Custom" : palette(namedOrID: preset)?.name ?? preset
    }

    func sgr(for role: AppearanceRole) -> String {
        let pair = roles[role] ?? Self.blueFallbackRoles[role]!
        let attributes = ["0"] + (pair.bold ? ["1"] : []) + (pair.dim ? ["2"] : [])
        return "\u{1b}["
            + (attributes + pair.foreground.foregroundCodes + pair.background.backgroundCodes)
            .joined(separator: ";") + "m"
    }

    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
        { return nil }
    }
    private static func validatePath(_ url: URL, directory: Bool) throws {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)
        guard value[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (value[.ownerAccountID] as? NSNumber)?.uint32Value == tractanda_uid(),
            let mode = value[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0
        else {
            throw TractandaError(
                "invalidAppearance", "TUI appearance settings must be private, owned regular files.")
        }
    }
    func validate() throws {
        guard (1...4).contains(version), Self.areComplete(roles), customRoles.map(Self.areComplete) ?? true,
            Self.validLibrary(savedPalettes), savedPalettes.count <= Self.maximumSavedPalettes,
            preset == Self.customPresetID || savedPalettes.contains(where: { $0.id == preset })
        else { throw TractandaError("invalidAppearance", "The TUI appearance file is invalid.") }
    }

    static func areComplete(_ roles: [AppearanceRole: AppearancePair]) -> Bool {
        roles.count == AppearanceRole.allCases.count
            && AppearanceRole.allCases.allSatisfy { roles[$0] != nil }
    }

    private static func migratingActivePane(_ roles: [AppearanceRole: AppearancePair])
        -> [AppearanceRole: AppearancePair]
    {
        var value = roles
        if value[.activePane] == nil { value[.activePane] = AppearanceRole.activePaneDefault }
        return value
    }

    private static func validLibrary(_ palettes: [AppearancePalette]) -> Bool {
        let ids = palettes.map { $0.id.lowercased() }
        let names = palettes.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive], locale: .current)
        }
        return palettes.allSatisfy {
            !$0.id.isEmpty && $0.id.caseInsensitiveCompare(customPresetID) != .orderedSame
                && !$0.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 64
                && $0.name.caseInsensitiveCompare(customPresetID) != .orderedSame
                && !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && areComplete($0.roles)
        } && Set(ids).count == ids.count && Set(names).count == names.count
    }

    private static func legacyID(_ value: String, library: [AppearancePalette]) -> String? {
        if value.caseInsensitiveCompare(customPresetID) == .orderedSame { return customPresetID }
        return library.first {
            $0.id.caseInsensitiveCompare(value) == .orderedSame
                || $0.name.caseInsensitiveCompare(value) == .orderedSame
        }?.id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...4).contains(sourceVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unsupported appearance version")
        }
        let library: [AppearancePalette]
        if container.contains(.savedPalettes) {
            library = try container.decode([AppearancePalette].self, forKey: .savedPalettes)
        } else {
            library = Self.shippedPalettes.palettes
        }
        let rawPreset =
            try container.decodeIfPresent(String.self, forKey: .preset)
            ?? Self.shippedPalettes.defaultPresetID
        guard let selected = Self.legacyID(rawPreset, library: library) else {
            throw DecodingError.dataCorruptedError(
                forKey: .preset, in: container, debugDescription: "Unknown appearance preset")
        }
        let decodedRoles = try container.decodeIfPresent(
            [AppearanceRole: AppearancePair].self, forKey: .roles)
        let displayed = Self.migratingActivePane(
            decodedRoles ?? library.first(where: { $0.id == selected })?.roles ?? Self.blueFallbackRoles)
        let retained =
            try container.decodeIfPresent([AppearanceRole: AppearancePair].self, forKey: .customRoles)
            .map(Self.migratingActivePane)
            ?? (selected == Self.customPresetID ? displayed : nil)
        self.init(
            version: sourceVersion, preset: selected, roles: displayed,
            cursor: try container.decodeIfPresent(CursorPreferences.self, forKey: .cursor) ?? .init(),
            showsDropShadows: try container.decodeIfPresent(Bool.self, forKey: .showsDropShadows) ?? false,
            customRoles: retained, savedPalettes: library)
        version = 4
    }

    static func load(from url: URL) throws -> TerminalAppearance {
        guard try attributes(url) != nil else { return .initial() }
        try validatePath(url.deletingLastPathComponent(), directory: true)
        try validatePath(url, directory: false)
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
            size.intValue <= maximumBytes
        else { throw TractandaError("invalidAppearance", "TUI appearance exceeds 128 KiB.") }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }
    func save(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.validatePath(parent, directory: true)
        if try Self.attributes(url) != nil { try Self.validatePath(url, directory: false) }
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else {
            throw TractandaError("invalidAppearance", "TUI appearance exceeds 128 KiB.")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
