import Foundation
import TractandaCore
import TractandaKanban
import TractandaServer
import TractandaWeb

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

let usage = """
    Tractanda — experimental local item server

      tractanda init STORE [--index-directory PATH]
      tractanda seed STORE [--index-directory PATH]
      tractanda configure-access STORE TAGGED_CONFIG_JSON OPERATION_ID [--index-directory PATH]
      tractanda serve STORE SOCKET [--max-requests N] [--index-directory PATH]
      tractanda daemon STORE SOCKET [--index-directory PATH] [--http-port PORT|--no-http] [--managed] [--view ID | --project-root ID --status-root ID [--project ID]]
      tractanda connections list|add|default|remove ...
      tractanda service prepare|install|activate|start|stop|status|uninstall ...
      tractanda uuid-v1 [COUNT]
      tractanda uuid-node
      tractanda inspect-uuid UUID
      tractanda --default COMMAND ARGUMENTS...
      tractanda --profile NAME COMMAND ARGUMENTS...
      tractanda --socket PATH COMMAND ARGUMENTS...
      tractanda request SOCKET [JSON_FILE]          (otherwise reads stdin)
      tractanda call SOCKET METHOD [ARGUMENTS_JSON] (otherwise reads stdin)
      tractanda info SOCKET
      tractanda get SOCKET ITEM_ID...
      tractanda query SOCKET EXPRESSION
      tractanda search SOCKET LITERAL_PHRASE
      tractanda history SOCKET ITEM_ID
      tractanda resolve SOCKET ITEM_ID PATH [ISO_TIMESTAMP]
      tractanda create SOCKET CLASS SUBJECT OPERATION_ID [BODY]
      tractanda edit SOCKET ITEM_ID BASE_REVISION OPERATION_ID FIELDS_JSON
      tractanda retype SOCKET ITEM_ID BASE_REVISION OPERATION_ID CLASS
      tractanda delete|restore|copy SOCKET ITEM_ID BASE_REVISION OPERATION_ID
      tractanda include|exclude|reset SOCKET ITEM_ID BASE_REVISION OPERATION_ID CATEGORY_ID
      tractanda criteria SOCKET ITEM_ID BASE_REVISION OPERATION_ID EXPRESSION
      tractanda rebuild SOCKET
      tractanda kanban SOCKET VIEW_ITEM_ID
      tractanda export-kanban SOCKET VIEW_ITEM_ID HTML_OR_JSON_FILE
      tractanda install-categories SOCKET TEMPLATE_JSON IANA_TIME_ZONE
      tractanda web SOCKET VIEW_ITEM_ID [--port N] [--session-file PATH]
      tractanda web SOCKET INITIAL_PROJECT_ID --project-root CATEGORY_ID --status-root CATEGORY_ID [--port N] [--session-file PATH]
      tractanda learning-status|learn|learning-reset SOCKET CATEGORY_ID
      tractanda suggest SOCKET CATEGORY_ID [EXPRESSION]
      tractanda suggest-categories SOCKET ITEM_ID [CATEGORY_ID...]
      tractanda learning-settings SOCKET CATEGORY_ID BASE_REVISION OPERATION_ID TAGGED_SETTINGS_JSON
      tractanda feedback SOCKET ITEM_ID BASE_REVISION OPERATION_ID CATEGORY_ID ACTION [MODEL_ID]
      tractanda semantic-status SOCKET
      tractanda semantic-configure SOCKET EXPECTED_CONFIG_ID_OR_- CONFIGURATION_JSON
      tractanda semantic-rebuild|semantic-reset SOCKET CONFIGURATION_ID OPERATION_ID
      tractanda semantic-search SOCKET TEXT
      tractanda semantic-results SOCKET QUERY_ID

    Feedback actions: accept, exclude, negative, dismiss, clear.
    Learning reset preserves canonical assignments and feedback. Use call for pagination.

    Fields use tagged JSON values, e.g. {"phone":{"type":"text","value":"123"}}.
    Mutations require an operation ID; reuse it with identical arguments when retrying.
    Stores default to single-user access. Shared stores admit configured OS users/groups.
    Set TRACTANDA_SERVER_USER to pin another account's daemon identity. This is not network JMAP.
    """

func output(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}
func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSON.encode(value))
}
func call(_ connection: ServerConnection, _ method: String, _ args: Any) throws -> Data {
    let request: [String: Any] = ["using": [ItemService.capability], "methodCalls": [[method, args, "cli"]]]
    let response = try connection.send(
        JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
    guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
        throw TractandaError("protocolError", "Invalid response.")
    }
    if let code = envelope["code"] as? String {
        throw TractandaError(code, envelope["message"] as? String ?? "")
    }
    guard let calls = envelope["methodResponses"] as? [[Any]], let first = calls.first,
        let result = first[1] as? [String: Any]
    else { throw TractandaError("protocolError", "Missing method response.") }
    if first[0] as? String == "error" {
        throw TractandaError(result["type"] as? String ?? "error", result["description"] as? String ?? "")
    }
    return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
}
func run() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    var options = ConnectionOptions()
    let hasConnectionOptions =
        args.first.map { ["--default", "--profile", "--socket", "--no-start"].contains($0) } ?? false
    try options.consume(&args)
    guard let command = args.first else {
        print(usage)
        return
    }
    if ["help", "--help", "-h"].contains(command) {
        print(usage)
        return
    }
    if command == "uuid-v1" || command == "inspect-uuid" || command == "uuid-node" {
        guard !hasConnectionOptions else {
            throw TractandaError("usage", "UUID utilities run locally, without a connection profile.")
        }
        if command == "uuid-node" {
            guard args.count == 1 else { throw TractandaError("usage", "Use uuid-node without arguments.") }
            let node = try UUIDHardwareNode.current()
            output(
                try JSONSerialization.data(
                    withJSONObject: [
                        "node": node.address, "source": node.source,
                        "interface": node.interfaceName ?? "", "isBuiltIn": node.isBuiltIn,
                    ], options: [.prettyPrinted, .sortedKeys]))
        } else if command == "uuid-v1" {
            guard args.count <= 2, let count = args.count == 2 ? Int(args[1]) : 1,
                (1...10_000).contains(count)
            else { throw TractandaError("usage", "Use uuid-v1 with a count from 1 through 10000.") }
            output(try JSON.encode((0..<count).map { _ in try UUID.makeVersion1().uuidString.lowercased() }))
        } else {
            guard args.count == 2, let uuid = UUID(uuidString: args[1]) else {
                throw TractandaError("usage", "Use inspect-uuid with a UUIDv1 value.")
            }
            let components = try UUIDVersion1Components(uuid)
            let result: [String: Any] = [
                "uuid": uuid.uuidString.lowercased(), "version": 1,
                "timestamp100Nanoseconds": String(components.timestamp),
                "timestampUTC": components.timestampUTC,
                "clockSequence": components.clockSequence, "node": components.nodeAddress,
                "nodeUsesGeneratedAddress": components.isGeneratedNode,
                "nodeIsLocallyAdministered": components.isLocallyAdministeredNode,
            ]
            output(
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
        }
        return
    }
    if try handleConnectionCommand(args) { return }
    let isStoreCommand = ["init", "seed", "serve", "configure-access"].contains(command)
    var selectedConnection: ServerConnection?
    if hasConnectionOptions {
        guard !isStoreCommand else {
            throw TractandaError("usage", "Connection options apply to client commands.")
        }
        selectedConnection = try options.resolve()
        args.insert(selectedConnection!.socketPath, at: 1)
    } else if args.count == 1, command == "info" {
        selectedConnection = try options.resolve()
        args.append(selectedConnection!.socketPath)
    }
    func require(_ count: Int) throws {
        guard args.count >= count else { throw TractandaError("usage", usage) }
    }
    try require(2)
    if isStoreCommand {
        var indexDirectory: URL?
        if let option = args.firstIndex(of: "--index-directory") {
            guard args.indices.contains(option + 1), !args[option + 1].hasPrefix("--"),
                args.dropFirst(option + 1).firstIndex(of: "--index-directory") == nil
            else { throw TractandaError("usage", usage) }
            indexDirectory = URL(fileURLWithPath: args[option + 1], isDirectory: true)
            args.removeSubrange(option...(option + 1))
        }
        let isManaged = command == "serve" && args.contains("--managed")
        if isManaged,
            !FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: args[1]).appendingPathComponent("items").path)
        {
            throw TractandaError("invalidStore", "Managed startup requires an existing initialized store.")
        }
        let store = try ItemStore(
            root: URL(fileURLWithPath: args[1], isDirectory: true), indexDirectory: indexDirectory)
        if command == "init" {
            output(try JSON.encode(["store": store.root.path, "state": store.state]))
            return
        }
        if command == "seed" {
            output(try JSON.encode(DemoFixture.seed(store)))
            return
        }
        if command == "configure-access" {
            try require(4)
            let value = try JSON.decode(ItemValue.self, Data(contentsOf: URL(fileURLWithPath: args[2])))
            output(try JSON.encode(store.configureAccess(value, operationID: args[3])))
            return
        }
        try require(3)
        var maxRequests: Int?
        if isManaged {
            guard args.count == 4, args[3] == "--managed" else { throw TractandaError("usage", usage) }
        } else if args.count > 3 {
            guard args.count == 5, args[3] == "--max-requests", let n = Int(args[4]), n > 0 else {
                throw TractandaError("usage", usage)
            }
            maxRequests = n
        }
        FileHandle.standardError.write(
            Data("Serving \(store.root.path) at \(args[2]) as UID \(store.ownerUID).\n".utf8))
        try LocalTransport.serve(
            ItemService(store: store), socket: args[2], maxRequests: maxRequests, isManaged: isManaged)
        return
    }
    let socket = args[1]
    let connection = try selectedConnection ?? ConnectionPreferences().resolve(socketPath: socket)
    switch command {
    case "install-categories":
        try require(4)
        let template = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2])))
        output(
            try call(
                connection, "TractandaCategory/installTemplate", ["template": template, "timeZone": args[3]]))
    case "learning-status", "learn", "learning-reset":
        try require(3)
        let method = command == "learn" ? "train" : command == "learning-reset" ? "reset" : "status"
        output(try call(connection, "TractandaLearning/\(method)", ["categoryID": args[2]]))
    case "suggest":
        try require(3)
        var arguments: [String: Any] = ["categoryID": args[2]]
        if args.count > 3 { arguments["expression"] = args[3] }
        output(try call(connection, "TractandaLearning/suggest", arguments))
    case "suggest-categories":
        try require(3)
        var arguments: [String: Any] = ["itemID": args[2]]
        if args.count > 3 { arguments["categoryIDs"] = Array(args.dropFirst(3)) }
        output(try call(connection, "TractandaLearning/categories", arguments))
    case "learning-settings":
        try require(6)
        output(
            try call(
                connection, "TractandaLearning/settings",
                [
                    "categoryID": args[2], "expectedRevisionID": args[3], "operationID": args[4],
                    "settings": try JSONSerialization.jsonObject(with: Data(args[5].utf8)),
                ]))
    case "feedback":
        try require(7)
        var arguments = [
            "itemID": args[2], "expectedRevisionID": args[3], "operationID": args[4],
            "categoryID": args[5], "action": args[6],
        ]
        if args.count > 7 { arguments["modelID"] = args[7] }
        output(try call(connection, "TractandaLearning/feedback", arguments))
    case "kanban", "export-kanban":
        try require(command == "kanban" ? 3 : 4)
        let snapshot = try KanbanRepository(client: ItemClient(connection: connection)).snapshot(for: args[2])
        if command == "kanban" {
            output(try JSON.encode(snapshot))
            return
        }
        let destination = URL(fileURLWithPath: args[3])
        let data =
            try destination.pathExtension.lowercased() == "html"
            ? KanbanPage.render(snapshot: snapshot) : JSON.encode(snapshot)
        try data.write(to: destination, options: .atomic)
        output(try JSON.encode(["exportedTo": destination.path, "viewItemID": args[2]]))
    case "web":
        try require(3)
        var port = 0
        var sessionFile: URL?
        var projectRootID: String?
        var statusRootID: String?
        var position = 3
        while position < args.count {
            guard position + 1 < args.count else { throw TractandaError("usage", usage) }
            switch args[position] {
            case "--port":
                guard let value = Int(args[position + 1]), (0...65535).contains(value) else {
                    throw TractandaError("usage", usage)
                }
                port = value
            case "--session-file": sessionFile = URL(fileURLWithPath: args[position + 1])
            case "--project-root": projectRootID = args[position + 1]
            case "--status-root": statusRootID = args[position + 1]
            default: throw TractandaError("usage", usage)
            }
            position += 2
        }
        var createdSessionFile: URL?
        defer { if let createdSessionFile { try? FileManager.default.removeItem(at: createdSessionFile) } }
        guard (projectRootID == nil) == (statusRootID == nil) else { throw TractandaError("usage", usage) }
        let board: LocalWebServer.BoardConfiguration
        if let projectRootID, let statusRootID {
            board = .init(
                projectBoard: .init(
                    initialProjectID: args[2], projectRootID: projectRootID, statusRootID: statusRootID))
        } else {
            board = .init(viewItemID: args[2])
        }
        try LocalWebServer.serve(connection: connection, board: board, port: port) { session in
            if let sessionFile {
                let parent = sessionFile.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
                guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                    ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0
                else {
                    throw TractandaError(
                        "unsafeSessionFile", "Use a private, owned directory for the web session file.")
                }
                try JSON.encode(session).write(to: sessionFile, options: .withoutOverwriting)
                createdSessionFile = sessionFile
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: sessionFile.path)
                output(
                    try JSON.encode([
                        "sessionFile": sessionFile.path,
                        "address": session.url.components(separatedBy: "#")[0],
                    ]))
            } else {
                output(try JSON.encode(session))
            }
        }
    case "request":
        let input =
            try args.count > 2
            ? Data(contentsOf: URL(fileURLWithPath: args[2])) : FileHandle.standardInput.readToEnd() ?? Data()
        output(try connection.send(input))
    case "call":
        try require(3)
        let input = try args.count > 3 ? Data(args[3].utf8) : FileHandle.standardInput.readToEnd() ?? Data()
        output(try call(connection, args[2], JSONSerialization.jsonObject(with: input)))
    case "info", "rebuild":
        output(
            try call(connection, command == "info" ? "TractandaStore/info" : "TractandaStore/rebuild", [:]))
    case "get":
        try require(3)
        output(try call(connection, "TractandaItem/get", ["ids": Array(args.dropFirst(2))]))
    case "query", "search":
        try require(3)
        output(
            try call(connection, "TractandaItem/query", [command == "query" ? "expression" : "text": args[2]])
        )
    case "history":
        try require(3)
        output(try call(connection, "TractandaItem/history", ["itemID": args[2]]))
    case "semantic-status":
        output(try call(connection, "TractandaSemantic/status", [:]))
    case "semantic-configure":
        try require(5)
        var request: [String: Any] = [
            "configuration": try JSONSerialization.jsonObject(with: Data(args[4].utf8))
        ]
        if args[3] != "-" { request["expectedConfigurationID"] = args[3] }
        output(try call(connection, "TractandaSemantic/configure", request))
    case "semantic-rebuild", "semantic-reset":
        try require(4)
        output(
            try call(
                connection,
                command == "semantic-rebuild" ? "TractandaSemantic/rebuild" : "TractandaSemantic/reset",
                ["expectedConfigurationID": args[2], "operationID": args[3]]))
    case "semantic-search":
        try require(3)
        let started = try call(connection, "TractandaSemantic/search", ["text": args[2]])
        guard let object = try JSONSerialization.jsonObject(with: started) as? [String: Any],
            let queryID = object["queryID"] as? String
        else { throw TractandaError("protocolError", "Semantic search did not return a query ID.") }
        var result = started
        for _ in 0..<200 {
            result = try call(connection, "TractandaSemantic/results", ["queryID": queryID])
            let response = try JSONSerialization.jsonObject(with: result) as? [String: Any]
            if response?["state"] as? String != "pending" { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        output(result)
    case "semantic-results":
        try require(3)
        output(try call(connection, "TractandaSemantic/results", ["queryID": args[2]]))
    case "resolve":
        try require(4)
        var arguments = ["itemID": args[2], "path": args[3]]
        if args.count > 4 { arguments["at"] = args[4] }
        output(try call(connection, "TractandaItem/resolve", arguments))
    case "create":
        try require(5)
        var fields: [String: ItemValue] = ["subject": .text(args[3])]
        if args.count > 5 { fields["body"] = .text(args[5]) }
        let request = CommitRequest(classID: args[2], changes: fields, operationID: args[4])
        output(try call(connection, "TractandaItem/commit", jsonObject(request)))
    case "edit", "retype", "delete", "restore", "copy", "include", "exclude", "reset", "criteria":
        try require(5)
        var request = CommitRequest(
            action: .revise, itemID: args[2], expectedRevisionID: args[3], operationID: args[4])
        switch command {
        case "edit":
            try require(6)
            request.changes = try JSON.decode([String: ItemValue].self, Data(args[5].utf8))
        case "retype":
            try require(6)
            request.action = .retype
            request.classID = args[5]
        case "copy": request.action = .copy
        case "delete", "restore": request.changes["isDeleted"] = .boolean(command == "delete")
        case "criteria":
            try require(6)
            request.changes["selection"] = .object([
                "language": .text(SpotlightQuery.profile), "expression": .text(args[5]),
            ])
        default:
            try require(6)
            // Compose a whole-property edit from the specified immutable base. A later
            // concurrent edit still fails the guard; a retry reconstructs identical intent.
            let data = try call(
                connection, "TractandaRevision/get", ["itemID": args[2], "revisionID": args[3]])
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let revision = try JSON.decode(
                Revision.self, JSONSerialization.data(withJSONObject: envelope["revision"]!))
            var overrides = revision.fields["categoryOverrides"]?.map ?? [:]
            overrides[args[5]] = command == "reset" ? nil : .text(command)
            request.changes["categoryOverrides"] = .object(overrides)
        }
        output(try call(connection, "TractandaItem/commit", jsonObject(request)))
    default: throw TractandaError("usage", usage)
    }
}

if CommandLine.arguments.dropFirst().first == "daemon" {
    do { try await daemonCommand(Array(CommandLine.arguments.dropFirst())) } catch {
        let failure = error as? TractandaError ?? TractandaError("error", String(describing: error))
        FileHandle.standardError.write((try? JSON.encode(failure)) ?? Data(failure.description.utf8))
        FileHandle.standardError.write(Data([10]))
        exit(1)
    }
} else {
    do { try run() } catch {
        let failure = error as? TractandaError ?? TractandaError("error", String(describing: error))
        FileHandle.standardError.write((try? JSON.encode(failure)) ?? Data(failure.description.utf8))
        FileHandle.standardError.write(Data([10]))
        exit(1)
    }
}
