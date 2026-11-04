import Foundation

/// Projects known saved-view fields into named headers and leaves extensions in the typed
/// remainder. Reference labels are stored display text and never select a category.
enum MessageViewFields {
    private static let scalars = [
        ("language", "X-View-Language"), ("expression", "X-View-Expression"), ("text", "X-View-Text"),
    ]
    private static let references = [("categoryPath", "X-View-Include"), ("excludedCategoryIDs", "X-View-Exclude")]

    static func write(_ value: ItemValue, emit: MessageHeaderEmitter) throws -> ItemValue? {
        guard var view = value.map else { return value }
        var emitted = false
        var labels = view["referenceLabels"]?.map
        var emittedLabel = false
        func output(_ name: String, _ value: String, referenceID: String? = nil) throws {
            var text = value
            if let referenceID, let label = labels?[referenceID]?.string {
                text += "; label=" + MessageHeaderText.escaped(label, quoted: true)
                labels?[referenceID] = nil
                emittedLabel = true
            }
            try emit(name, text)
            emitted = true
        }
        for (field, header) in scalars {
            if let text = view[field]?.string, MessageHeaderText.isLiteral(text) {
                try output(header, text)
                view[field] = nil
            }
        }
        for (field, header) in references {
            if let items = MessageKnownFields.currentReferences(view[field]) {
                for item in items { try output(header, item.itemID, referenceID: item.itemID) }
                view[field] = nil
            }
        }
        if let rows = view["sort"]?.array, !rows.isEmpty {
            let lines = rows.compactMap(sortLine)
            if lines.count == rows.count {
                for line in lines { try output("X-View-Sort", line.text, referenceID: line.id) }
                view["sort"] = nil
            }
        }
        if var table = view["presentation"]?.map {
            var tableEmitted = false
            if let profile = table["profile"]?.string, MessageHeaderText.isLiteral(profile) {
                try output("X-View-Presentation", profile)
                table["profile"] = nil
                tableEmitted = true
            }
            if let columns = table["columns"]?.array, !columns.isEmpty {
                let lines = columns.compactMap(columnLine)
                if lines.count == columns.count {
                    for line in lines { try output("X-View-Column", line.text, referenceID: line.id) }
                    table["columns"] = nil
                    tableEmitted = true
                }
            }
            if let sections = MessageKnownFields.currentReferences(table["sections"]) {
                let order = collapseOrder(table["collapsedSections"], sections: sections)
                for section in sections {
                    let state = order.map { ranks in
                        ranks[section.itemID].map { "; collapsed=yes; collapsed-order=" + String($0) }
                            ?? "; collapsed=no"
                    } ?? ""
                    try output("X-View-Section", section.itemID + state, referenceID: section.itemID)
                }
                table["sections"] = nil
                if order != nil { table["collapsedSections"] = nil }
                tableEmitted = true
            }
            view["presentation"] = tableEmitted && table.isEmpty ? nil : .object(table)
        }
        if emittedLabel, let labels { view["referenceLabels"] = labels.isEmpty ? nil : .object(labels) }
        return emitted && view.isEmpty ? nil : .object(view)
    }

    static func read(_ headers: inout MessageHeaderReader, remaining: ItemValue?) throws -> ItemValue? {
        var selected: [String: ItemValue] = [:]
        var table: [String: ItemValue] = [:]
        var labels: [String: ItemValue] = [:]
        for (field, header) in scalars {
            if let text = try headers.single(header.lowercased()) {
                selected[field] = .text(try MessageHeaderText.literal(text))
            }
        }
        for (field, header) in references {
            let rows = headers.many(header.lowercased())
            if !rows.isEmpty {
                selected[field] = .list(try rows.map { row in
                    let (id, parameters) = try referenceParameters(row)
                    var rest = parameters
                    try readLabel(&rest, id: id, labels: &labels)
                    try requireNoParameters(rest)
                    return .reference(ItemReference(id))
                })
            }
        }
        let sort = headers.many("x-view-sort")
        if !sort.isEmpty { selected["sort"] = .list(try sort.map { try readSort($0, labels: &labels) }) }
        if let profile = try headers.single("x-view-presentation") {
            table["profile"] = .text(try MessageHeaderText.literal(profile))
        }
        let columns = headers.many("x-view-column")
        if !columns.isEmpty { table["columns"] = .list(try columns.map { try readColumn($0, labels: &labels) }) }
        let sections = headers.many("x-view-section")
        if !sections.isEmpty {
            let values = try sections.map { try readSection($0, labels: &labels) }
            table["sections"] = .list(values.map(\.reference))
            if values.contains(where: { $0.collapsed != nil }) {
                guard values.allSatisfy({ $0.collapsed != nil }) else {
                    throw MessageHeaderText.invalid("Section state must be present on every compact section.")
                }
                let collapsed = values.filter { $0.collapsed == true }
                if collapsed.contains(where: { $0.rank != nil }) {
                    let ranked = collapsed.compactMap { entry in entry.rank.map { ($0, entry.reference) } }
                        .sorted { $0.0 < $1.0 }
                    guard ranked.map(\.0) == Array(0..<collapsed.count) else {
                        throw MessageHeaderText.invalid("Invalid collapsed section order.")
                    }
                    table["collapsedSections"] = .list(ranked.map(\.1))
                } else {
                    table["collapsedSections"] = .list(collapsed.map(\.reference))
                }
            }
        }
        guard !selected.isEmpty || !table.isEmpty || !labels.isEmpty else { return remaining }
        var view = try remainderMap(remaining)
        for (key, value) in selected { try MessageRecordCodec.insert(value, key: key, into: &view) }
        if !table.isEmpty {
            var presentation = try remainderMap(view["presentation"])
            for (key, value) in table { try MessageRecordCodec.insert(value, key: key, into: &presentation) }
            view["presentation"] = .object(presentation)
        }
        if !labels.isEmpty {
            var retained = try remainderMap(view["referenceLabels"])
            for (id, value) in labels { try MessageRecordCodec.insert(value, key: id, into: &retained) }
            view["referenceLabels"] = .object(retained)
        }
        return .object(view)
    }

    private static func remainderMap(_ value: ItemValue?) throws -> [String: ItemValue] {
        guard let value else { return [:] }
        guard let fields = value.map else { throw MessageHeaderText.invalid("View headers conflict with a typed field.") }
        return fields
    }

    private static func referenceParameters(_ row: String) throws -> (String, [String: String]) {
        var tokens = MessageHeaderTokens(row)
        let id = try tokens.takeWord(until: 59)
        try Identifier.validate(id)
        return (id, try tokens.parameters(afterValue: true))
    }

    private static func readLabel(
        _ parameters: inout [String: String], id: String?, labels: inout [String: ItemValue]
    ) throws {
        guard let label = parameters.removeValue(forKey: "label") else { return }
        guard let id else { throw MessageHeaderText.invalid("A view label requires a category reference.") }
        if let retained = labels[id]?.string {
            guard retained.utf8.elementsEqual(label.utf8) else {
                throw MessageHeaderText.invalid("Conflicting view labels for one category reference.")
            }
            return
        }
        labels[id] = .text(label)
    }

    private static func requireNoParameters(_ parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw MessageHeaderText.invalid("Unknown view header parameter.") }
    }

    private static func parameterText(_ text: String) -> String {
        if !text.isEmpty, MessageHeaderText.isLiteral(text),
            !text.utf8.contains(where: { MessageHeaderText.isWhitespace($0) || [34, 59, 61, 92].contains($0) }) {
            return text
        }
        return MessageHeaderText.escaped(text, quoted: true)
    }

    private static func selector(_ map: [String: ItemValue]) -> (text: String, id: String?)? {
        if let property = map["property"]?.string, map["categoryRootID"] == nil {
            return ("property=" + parameterText(property), nil)
        }
        if let ref = map["categoryRootID"]?.link, ref.revisionID == nil, map["property"] == nil {
            return ("category=" + ref.itemID, ref.itemID)
        }
        return nil
    }

    private static func readSelector(_ parameters: inout [String: String], labels: inout [String: ItemValue]) throws
        -> [String: ItemValue] {
        let property = parameters.removeValue(forKey: "property")
        let category = parameters.removeValue(forKey: "category")
        try readLabel(&parameters, id: category, labels: &labels)
        switch (property, category) {
        case (let property?, nil): return ["property": .text(property)]
        case (nil, let id?):
            try Identifier.validate(id)
            return ["categoryRootID": .reference(ItemReference(id))]
        default: throw MessageHeaderText.invalid("View header requires exactly one property or category selector.")
        }
    }

    private static func sortLine(_ value: ItemValue) -> (text: String, id: String?)? {
        guard let map = value.map, let target = selector(map),
            Set(map.keys).isSubset(of: ["property", "categoryRootID", "isAscending"])
        else { return nil }
        guard let direction = map["isAscending"] else { return target }
        guard let ascending = direction.booleanValue else { return nil }
        return (target.text + (ascending ? "; direction=ascending" : "; direction=descending"), target.id)
    }

    private static func readSort(_ row: String, labels: inout [String: ItemValue]) throws -> ItemValue {
        var tokens = MessageHeaderTokens(row)
        var parameters = try tokens.parameters()
        var map = try readSelector(&parameters, labels: &labels)
        if let direction = parameters.removeValue(forKey: "direction") {
            switch direction {
            case "ascending": map["isAscending"] = .boolean(true)
            case "descending": map["isAscending"] = .boolean(false)
            default: throw MessageHeaderText.invalid("Unknown view sort direction.")
            }
        }
        try requireNoParameters(parameters)
        return .object(map)
    }

    private static func columnLine(_ value: ItemValue) -> (text: String, id: String?)? {
        guard let map = value.map, map.count == 3, let target = selector(map),
            let title = map["title"]?.string, let width = map["width"]?.integerValue
        else { return nil }
        return (target.text + "; title=" + MessageHeaderText.escaped(title, quoted: true) + "; width=" + String(width), target.id)
    }

    private static func readColumn(_ row: String, labels: inout [String: ItemValue]) throws -> ItemValue {
        var tokens = MessageHeaderTokens(row)
        var parameters = try tokens.parameters()
        var map = try readSelector(&parameters, labels: &labels)
        guard let title = parameters.removeValue(forKey: "title"),
            let width = parameters.removeValue(forKey: "width").flatMap({ Int64($0) })
        else { throw MessageHeaderText.invalid("View column requires a title and width.") }
        map["title"] = .text(title)
        map["width"] = .integer(width)
        try requireNoParameters(parameters)
        return .object(map)
    }

    private static func collapseOrder(_ value: ItemValue?, sections: [ItemReference]) -> [String: Int]? {
        guard let values = value?.array else { return nil }
        let ids = Set(sections.map(\.itemID))
        guard ids.count == sections.count else { return nil }
        var ranks: [String: Int] = [:]
        for (index, item) in values.enumerated() {
            guard let link = item.link, link.revisionID == nil, ids.contains(link.itemID),
                ranks.updateValue(index, forKey: link.itemID) == nil else { return nil }
        }
        return ranks
    }

    private static func readSection(_ row: String, labels: inout [String: ItemValue]) throws
        -> (reference: ItemValue, collapsed: Bool?, rank: Int?) {
        let (id, parameters) = try referenceParameters(row)
        var rest = parameters
        try readLabel(&rest, id: id, labels: &labels)
        let collapsed: Bool?
        switch rest.removeValue(forKey: "collapsed") {
        case nil: collapsed = nil
        case "yes": collapsed = true
        case "no": collapsed = false
        default: throw MessageHeaderText.invalid("Unknown view section state.")
        }
        let rank: Int?
        if let value = rest.removeValue(forKey: "collapsed-order") {
            guard collapsed == true, let index = Int(value), index >= 0 else {
                throw MessageHeaderText.invalid("Invalid collapsed section ordinal.")
            }
            rank = index
        } else { rank = nil }
        try requireNoParameters(rest)
        return (.reference(ItemReference(id)), collapsed, rank)
    }
}
