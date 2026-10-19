import Foundation

enum CanonicalRecordPath {
    /// The directory is publication placement, not item creation, logical modification or UUID time.
    static func validate(_ path: String, itemID: String, revisionID: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 8, parts[0] == "items", parts[6] == Substring(itemID),
            parts[7] == Substring(revisionID + ".tractanda"),
            (try? Identifier.validate(itemID)) != nil, (try? Identifier.validate(revisionID)) != nil
        else { return false }
        for index in 1...5 {
            guard parts[index].utf8.count == (index == 1 ? 4 : 2),
                parts[index].utf8.allSatisfy({ (48...57).contains($0) })
            else { return false }
        }
        let timestamp = "\(parts[1])-\(parts[2])-\(parts[3])T\(parts[4]):\(parts[5]):00Z"
        return (try? RevisionTimestamp(timestamp)) != nil
    }
}
