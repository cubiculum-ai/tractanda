import Foundation
import TractandaCore
import TractandaKanban

public enum KanbanPage {
    public static func manual() throws -> Data {
        guard
            let resource = Bundle.module.url(
                forResource: "Manual", withExtension: "html", subdirectory: "Resources")
        else { throw TractandaError("missingResource", "The web manual resource is unavailable.") }
        return try Data(contentsOf: resource)
    }
    private static func escapedJSON(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    public static func render(
        snapshot: [String: JSONValue]? = nil, viewItemID: String? = nil,
        projectBoard: KanbanRepository.ProjectBoardConfiguration? = nil, nonce: String = ""
    ) throws -> Data {
        guard
            let resource = Bundle.module.url(
                forResource: "Kanban", withExtension: "html", subdirectory: "Resources")
        else {
            throw TractandaError("missingResource", "The web client resource bundle is unavailable.")
        }
        var configuration: [String: JSONValue] = ["mode": .string(snapshot == nil ? "live" : "snapshot")]
        if let viewItemID { configuration["viewItemID"] = .string(viewItemID) }
        if let projectBoard {
            configuration["projectBoard"] = .object([
                "initialProjectID": .string(projectBoard.initialProjectID),
                "projectRootID": .string(projectBoard.projectRootID),
                "statusRootID": .string(projectBoard.statusRootID),
            ])
        }
        let template = try String(contentsOf: resource, encoding: .utf8)
        let liveCode = try String(
            contentsOf: resource.deletingLastPathComponent().appendingPathComponent("LiveClient.js"),
            encoding: .utf8)
        let learningCode = try String(
            contentsOf: resource.deletingLastPathComponent().appendingPathComponent("LearningClient.js"),
            encoding: .utf8)
        let boardData = try snapshot.map { escapedJSON(try JSON.encode($0)) } ?? "null"
        return Data(
            template.replacingOccurrences(of: "@@LIVE_CLIENT@@", with: liveCode)
                .replacingOccurrences(of: "@@LEARNING_CLIENT@@", with: learningCode)
                .replacingOccurrences(of: "@@SCRIPT_NONCE@@", with: nonce)
                .replacingOccurrences(of: "@@BODY_CLASS@@", with: snapshot == nil ? "needs-login" : "")
                .replacingOccurrences(
                    of: "@@CLIENT_CONFIG@@", with: escapedJSON(try JSON.encode(configuration))
                )
                .replacingOccurrences(of: "@@BOARD_DATA@@", with: boardData).utf8)
    }
}
