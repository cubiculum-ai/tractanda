import Foundation

enum KanbanTaskOrder {
    /// Saved views retain the native query order. Default boards sort priorities
    /// naturally (P2 before P10), keeping the query order for equal priorities.
    static func ordered(_ tasks: [JSONValue], usesViewSort: Bool) -> [JSONValue] {
        guard !usesViewSort else { return tasks }
        let locale = Locale(identifier: "en_US_POSIX")
        return tasks.enumerated().sorted { left, right in
            let a = priority(left.element)
            let b = priority(right.element)
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            let comparison = a.compare(b, options: [.numeric, .caseInsensitive], locale: locale)
            return comparison == .orderedSame ? left.offset < right.offset : comparison == .orderedAscending
        }.map(\.element)
    }

    private static func priority(_ task: JSONValue) -> String {
        (task.objectValue?["priority"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
