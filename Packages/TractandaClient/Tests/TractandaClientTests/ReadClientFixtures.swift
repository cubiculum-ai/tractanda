import Foundation

/// Independent fixture mapping from canonical test objects into the newly specified wire shape.
func fixtureTagged(_ value: Any, toWire: Bool) throws -> Any {
    var tag = value as! [String: Any]
    switch tag["type"] as? String {
    case "integer":
        if toWire {
            tag["value"] = (tag["value"] as! NSNumber).stringValue
        } else {
            let text = tag["value"] as! String
            guard let integer = Int64(text), String(integer) == text else {
                throw FixtureReadError.invalidInteger
            }
            tag["value"] = integer
        }
    case "list": tag["value"] = try (tag["value"] as! [Any]).map { try fixtureTagged($0, toWire: toWire) }
    case "object":
        tag["value"] = try (tag["value"] as! [String: Any]).mapValues {
            try fixtureTagged($0, toWire: toWire)
        }
    default: break
    }
    return tag
}
private enum FixtureReadError: Error { case invalidInteger }
func fixtureReadRecord(_ revision: Any, item: Bool) throws -> [String: Any] {
    let revision = revision as! [String: Any]
    let fields = revision["fields"] as! [String: Any]
    let itemID = (fields["itemID"] as! [String: Any])["value"] as! String
    let revisionID = (fields["revisionID"] as! [String: Any])["value"] as! String
    var record: [String: Any] = [
        "id": item ? itemID : revisionID,
        "formatVersion": revision["formatVersion"] ?? 1,
        "fields": try fields.mapValues { try fixtureTagged($0, toWire: true) },
    ]
    if item {
        record["revisionId"] = revisionID
        record["resolution"] = [
            "itemID": itemID, "stateToken": "ready-token", "status": "ready",
            "representativeRevisionID": revisionID, "detailsComplete": true,
        ]
    } else {
        record["itemId"] = itemID
    }
    return record
}
func fixtureReadPayload(_ method: String, _ value: Any) throws -> Any {
    guard var payload = value as? [String: Any] else { return value }
    if [
        "TractandaItem/get", "TractandaItem/getBounded", "TractandaItem/history", "TractandaRevision/get",
        "TractandaItem/query",
    ].contains(method) {
        payload["accountId"] = "00112233-4455-6677-8899-aabbccddeeff"
    }
    if ["TractandaItem/get", "TractandaItem/getBounded", "TractandaItem/history", "TractandaRevision/get"]
        .contains(method)
    {
        let item = method == "TractandaItem/get" || method == "TractandaItem/getBounded"
        let revisions = payload["list"] as? [Any] ?? payload["revision"].map { [$0] } ?? []
        var list = try revisions.map { try fixtureReadRecord($0, item: item) }
        for summary in payload["unresolved"] as? [[String: Any]] ?? [] {
            var resolution = summary
            resolution["detailsComplete"] = false
            list.append([
                "id": summary["itemID"]!, "revisionId": NSNull(), "formatVersion": NSNull(),
                "fields": NSNull(), "resolution": resolution,
            ])
        }
        payload["list"] = list
        payload.removeValue(forKey: "unresolved")
        payload.removeValue(forKey: "revision")
        payload["state"] = payload["state"] ?? "store-state"
        payload["notFound"] = payload["notFound"] ?? []
    }
    if method == "TractandaItem/prepareCapture" {
        for key in ["request", "commitRequest"] {
            if var request = payload[key] as? [String: Any],
                let changes = request["changes"] as? [String: Any]
            {
                request["changes"] = try changes.mapValues { try fixtureTagged($0, toWire: true) }
                payload[key] = request
            }
        }
    }
    return payload
}
