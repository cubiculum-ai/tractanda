import Foundation
import TractandaCore

/// Exact native intent, retained before sending. Replay never consults a newer model or item.
enum LearningEdit: Codable, Equatable, Sendable {
    struct Feedback: Codable, Equatable, Sendable {
        let categoryID: String
        let itemID: String
        let expectedRevisionID: String
        let operationID: String
        let action: LearningFeedbackAction
        let modelID: String?
    }
    struct Settings: Codable, Equatable, Sendable {
        let categoryID: String
        let expectedRevisionID: String
        let operationID: String
        let settings: ItemValue
    }
    case feedback(Feedback)
    case settings(Settings)

    var categoryID: String {
        switch self {
        case .feedback(let request): request.categoryID
        case .settings(let request): request.categoryID
        }
    }
    var operationID: String {
        switch self {
        case .feedback(let request): request.operationID
        case .settings(let request): request.operationID
        }
    }
    var itemID: String {
        switch self {
        case .feedback(let request): request.itemID
        case .settings(let request): request.categoryID
        }
    }

    func validate() throws {
        try Identifier.validate(categoryID)
        try Identifier.validate(operationID)
        switch self {
        case .feedback(let request):
            try Identifier.validate(request.itemID)
            try Identifier.validate(request.expectedRevisionID)
            if let id = request.modelID { try Identifier.validate(id) }
        case .settings(let request):
            try Identifier.validate(request.expectedRevisionID)
            _ = try CategoryLearningSettings(request.settings)
        }
    }

    func send(using client: ItemClient) throws -> CommitResult {
        try validate()
        let method: String
        let data: Data
        switch self {
        case .feedback(let request):
            method = "TractandaLearning/feedback"
            data = try JSON.encode(request)
        case .settings(let request):
            method = "TractandaLearning/settings"
            data = try JSON.encode(request)
        }
        let arguments = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let result = try JSON.decode(CommitResult.self, client.call(method, arguments: arguments))
        guard result.revision.itemID == itemID,
            result.revision.fields["operationID"]?.string == operationID
        else { throw TractandaError("protocolError", "Learning receipt does not match the saved edit.") }
        return result
    }
}
