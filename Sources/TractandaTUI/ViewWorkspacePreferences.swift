import CTractandaPlatform
import Foundation
import TractandaCore

/// Personal TUI-only state.  Pins deliberately never alter a shared view revision.
struct ViewWorkspacePreferences: Codable, Equatable, Sendable {
    // Version 4 adds the shared preview height. It remains private client
    // state: neither value is ever copied into a view revision.
    var version = 4
    var pinnedViewIDs: [String] = []
    var categoryConnectedTree = false
    var categoryRightMode = "items"
    var categorySplitWidth = 0.333
    var selectorSplitWidth = 0.333
    var previewVisible = true
    /// Requested content rows, retained even while a compact terminal temporarily clamps it.
    var previewContentHeight = 3

    private enum CodingKeys: String, CodingKey {
        case version, pinnedViewIDs, categoryConnectedTree, categoryRightMode, categorySplitWidth
        case selectorSplitWidth, previewVisible, previewContentHeight
    }

    init(
        version: Int = 4, pinnedViewIDs: [String] = [], categoryConnectedTree: Bool = false,
        categoryRightMode: String = "items", categorySplitWidth: Double = 0.333,
        selectorSplitWidth: Double = 0.333, previewVisible: Bool = true, previewContentHeight: Int = 3
    ) {
        self.version = version
        self.pinnedViewIDs = pinnedViewIDs
        self.categoryConnectedTree = categoryConnectedTree
        self.categoryRightMode = categoryRightMode
        self.categorySplitWidth = categorySplitWidth
        self.selectorSplitWidth = selectorSplitWidth
        self.previewVisible = previewVisible
        self.previewContentHeight = previewContentHeight
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        pinnedViewIDs = try values.decodeIfPresent([String].self, forKey: .pinnedViewIDs) ?? []
        categoryConnectedTree = try values.decodeIfPresent(Bool.self, forKey: .categoryConnectedTree) ?? false
        categoryRightMode = try values.decodeIfPresent(String.self, forKey: .categoryRightMode) ?? "items"
        categorySplitWidth = try values.decodeIfPresent(Double.self, forKey: .categorySplitWidth) ?? 0.333
        selectorSplitWidth = try values.decodeIfPresent(Double.self, forKey: .selectorSplitWidth) ?? 0.333
        previewVisible = try values.decodeIfPresent(Bool.self, forKey: .previewVisible) ?? true
        previewContentHeight = try values.decodeIfPresent(Int.self, forKey: .previewContentHeight) ?? 3
    }

    private static let maximumBytes = 1_048_576

    /// attributesOfItem inspects the link itself, including a dangling link.
    private static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
        { return nil }
    }

    private static func validate(_ url: URL, directory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == tractanda_uid(),
            let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0
        else {
            throw TractandaError(
                "invalidPreferences", "TUI view preferences must be private, owned regular files.")
        }
    }

    private func validate() throws {
        guard (1...4).contains(version), pinnedViewIDs.count <= 1_024,
            Set(pinnedViewIDs).count == pinnedViewIDs.count,
            pinnedViewIDs.allSatisfy({ (try? Identifier.validate($0)) != nil }),
            categoryRightMode == "items" || categoryRightMode == "category",
            (0.20...0.70).contains(categorySplitWidth),
            (0.20...0.70).contains(selectorSplitWidth), (1...1_000).contains(previewContentHeight)
        else { throw TractandaError("invalidPreferences", "The TUI view preferences file is invalid.") }
    }

    static func load(from url: URL) throws -> ViewWorkspacePreferences {
        guard try attributesIfPresent(url) != nil else { return Self() }
        try validate(url.deletingLastPathComponent(), directory: true)
        try validate(url, directory: false)
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
            size.intValue <= maximumBytes
        else { throw TractandaError("invalidPreferences", "TUI view preferences exceed 1 MiB.") }
        let data = try Data(contentsOf: url)
        var value = try JSONDecoder().decode(Self.self, from: data)
        // Synthesised decoding supplies the new defaults for version-one files.  Normalize the
        // in-memory value so the next ordinary preference save performs the harmless migration.
        if value.version < 4 { value.version = 4 }
        try value.validate()
        return value
    }

    func save(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.validate(parent, directory: true)
        if try Self.attributesIfPresent(url) != nil { try Self.validate(url, directory: false) }
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else {
            throw TractandaError("invalidPreferences", "TUI view preferences exceed 1 MiB.")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
