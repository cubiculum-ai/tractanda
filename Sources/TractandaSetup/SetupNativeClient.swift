import Foundation
import TractandaCore

struct SetupNativeClient {
    let socket: String
    let serverUser: String

    func call(_ method: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let bytes = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, arguments, "setup"]],
        ])
        let response = try ServerConnection(socketPath: socket, serverUser: serverUser).send(bytes)
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
            let calls = envelope["methodResponses"] as? [[Any]], calls.count == 1, calls[0].count == 3,
            let result = calls[0][1] as? [String: Any], calls[0][0] as? String == method
        else { throw SetupError("Native installer request failed: \(method).") }
        return result
    }

    /// Optional template records and fresh sample items are created through the ordinary API.
    /// Every item receives the initial human owner's private permission policy.
    func seed(owner: String, instance: String, release: URL) throws -> [String: String] {
        let account = try SystemAccountDirectory().user(named: owner)
        let permissions: [String: Any] = [
            "type": "object",
            "value": [
                "profile": text(ItemPermissions.profile), "owner": text(owner),
                "group": text(account.primaryGroupName), "mode": ["type": "integer", "value": 0o600],
                "acl": ["type": "object", "value": [:]],
            ],
        ]
        let templateURL = release.appendingPathComponent("templates/starter-categories.json")
        guard
            var template = try JSONSerialization.jsonObject(with: Data(contentsOf: templateURL))
                as? [String: Any],
            var entries = template["entries"] as? [[String: Any]]
        else { throw SetupError("Invalid sample category template.") }
        for index in entries.indices {
            guard var fields = entries[index]["fields"] as? [String: Any] else {
                throw SetupError("Invalid sample category fields.")
            }
            fields["permissions"] = permissions
            entries[index]["fields"] = fields
        }
        template["entries"] = entries
        let installed = try call(
            "TractandaCategory/installTemplate",
            [
                "template": template, "timeZone": TimeZone.current.identifier,
            ])
        guard let items = installed["items"] as? [String: String], let status = items["status"],
            let ready = items["status.ready"], let doing = items["status.doing"],
            let done = items["status.done"]
        else { throw SetupError("Sample template did not return the expected categories.") }
        let selection: [String: Any] = [
            "type": "object",
            "value": [
                "language": text("tractanda.spotlight.v0"), "expression": text("itemID == \"\""),
            ],
        ]
        func create(_ key: String, _ fields: [String: Any]) throws -> String {
            var fields = fields
            fields["permissions"] = permissions
            let result = try call(
                "TractandaItem/commit",
                [
                    "action": "create", "classID": "Item",
                    "operationID": "setup-sample-v1-" + instance + "-" + key,
                    "changes": fields, "unset": [],
                ])
            guard let revision = result["revision"] as? [String: Any],
                let values = revision["fields"] as? [String: Any],
                let identity = values["itemID"] as? [String: Any], let value = identity["value"] as? String
            else { throw SetupError("Sample commit did not return an item identity.") }
            return value
        }
        let projects = try create(
            "projects",
            [
                "subject": text("Project"), "selection": selection,
                "categoryParents": references([items["what"]].compactMap { $0 }),
            ])
        let project = try create(
            "project",
            [
                "subject": text("Welcome"), "selection": selection, "categoryParents": references([projects]),
                "defaultCategory": reference(ready), "completionCategory": reference(done),
            ])
        _ = try create(
            "welcome",
            [
                "subject": text("Explore your shared knowledge base"),
                "body": text(
                    "Items can belong to several categories at once. Select categories to narrow a view; edit this sample or delete any optional category. Nothing here is required by the category engine."
                ),
                "categoryOverrides": [
                    "type": "object", "value": [project: text("include"), ready: text("include")],
                ],
            ])
        _ = try create(
            "view",
            [
                "subject": text("Welcome project"),
                "viewDefinition": [
                    "type": "object",
                    "value": [
                        "language": text("tractanda.spotlight.v0"),
                        "categoryPath": references([project, status]),
                        "presentation": [
                            "type": "object",
                            "value": [
                                "profile": text("tractanda.table.v0"),
                                "sections": references([ready, doing, done]),
                            ],
                        ],
                    ],
                ],
                "captureCategories": references([project]), "defaultCategory": reference(ready),
                "completionCategory": reference(done),
            ])
        return ["projectRootID": projects, "statusRootID": status, "projectID": project]
    }

    private func text(_ value: String) -> [String: Any] { ["type": "text", "value": value] }
    private func reference(_ value: String) -> [String: Any] {
        ["type": "reference", "value": ["itemID": value]]
    }
    private func references(_ values: [String]) -> [String: Any] {
        ["type": "list", "value": values.map(reference)]
    }
}
