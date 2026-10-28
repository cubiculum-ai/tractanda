import Foundation
import TractandaClient
import TractandaCore

typealias CLIPrivateEnrollmentSender = (ServerConnection, Data) throws -> Data

/// Codes travel only through the marked private session and explicit TTY/private files.
/// Normal JSON output contains only invitation metadata or the nonsecret job summary.
@discardableResult
func clusterEnrollmentCommand(
    arguments: [String], options: ConnectionOptions,
    output: (Data) -> Void = { print(String(decoding: $0, as: UTF8.self)) },
    sendForTesting: CLIPrivateEnrollmentSender? = nil,
    prepareNewForTesting: ((String, PersonalEnrollmentInvitationMetadata) throws -> ServerConnection)? = nil
) throws -> Bool {
    let help =
        "Use cluster invite [--hostname DNS] [--fallback-host DNS] [--out PRIVATE_FILE] [--resume] [--json], cluster join --hostname DNS [--prepare-new NAME | --replace-expired] [--code-file PRIVATE_FILE] [--no-wait] [--json], or cluster join-status|resume [--operation-id UUID] [--json]. --prepare-new explicitly prepares an empty outbound-only target through standard Setup."
    guard arguments.first == "cluster" else { return false }
    guard arguments.count >= 2 else { throw TractandaError("usage", help) }
    if arguments[1] == "status" { return false }
    let action = arguments[1]
    guard ["invite", "join", "join-status", "resume"].contains(action) else {
        throw TractandaError("usage", help)
    }
    var values: [String: String] = [:]
    var flags = Set<String>()
    var fallback: [String] = []
    var index = 2
    while index < arguments.count {
        let flag = arguments[index]
        if ["--json", "--resume", "--no-wait", "--replace-expired"].contains(flag) {
            guard flags.insert(flag).inserted else { throw TractandaError("usage", help) }
            index += 1
            continue
        }
        guard
            ["--hostname", "--fallback-host", "--out", "--code-file", "--operation-id", "--prepare-new"]
                .contains(flag),
            index + 1 < arguments.count, !arguments[index + 1].isEmpty,
            !arguments[index + 1].hasPrefix("--")
        else { throw TractandaError("usage", help) }
        let value = arguments[index + 1]
        if flag == "--fallback-host" {
            fallback.append(value)
        } else {
            guard values.updateValue(value, forKey: flag) == nil else { throw TractandaError("usage", help) }
        }
        index += 2
    }
    let json = flags.contains("--json")
    switch action {
    case "invite":
        guard Set(values.keys).isSubset(of: ["--hostname", "--out"]), fallback.count <= 3,
            flags.isSubset(of: ["--json", "--resume"]),
            !json || values["--out"] != nil,
            !flags.contains("--resume") || (values["--hostname"] == nil && fallback.isEmpty)
        else {
            throw TractandaError(
                "usage", help + " Invitation --json requires --out; the code is never JSON output.")
        }
        // Verify delivery before issuing or redisplaying a grant. A later race/failure
        // leaves the exact unused invitation retained for explicit private --resume.
        if let path = values["--out"] {
            try ClusterEnrollmentPrivateInput.validateNewPrivateOutputFile(path)
        } else {
            try ClusterEnrollmentPrivateInput.validateTerminalOutput()
        }
    case "join":
        guard Set(values.keys).isSubset(of: ["--hostname", "--code-file", "--prepare-new"]),
            values["--hostname"] != nil,
            fallback.isEmpty, flags.isSubset(of: ["--json", "--no-wait", "--replace-expired"]),
            values["--prepare-new"] == nil || !flags.contains("--replace-expired")
        else { throw TractandaError("usage", help) }
        if let instance = values["--prepare-new"] {
            guard options.socketPath == nil, options.profile == nil || options.profile == instance else {
                throw TractandaError(
                    "usage",
                    "--prepare-new cannot replace an explicit socket or a different selected profile.")
            }
        }
    default:
        guard Set(values.keys).isSubset(of: ["--operation-id"]), fallback.isEmpty,
            flags.isSubset(of: ["--json"])
        else { throw TractandaError("usage", help) }
    }
    var selected = options
    selected.startsService = false
    var preparedConnection: ServerConnection?
    func connection() throws -> ServerConnection {
        if let preparedConnection { return preparedConnection }
        let resolved = try selected.resolve()
        preparedConnection = resolved
        return resolved
    }
    func call(_ method: String, _ arguments: JMAPValue) throws -> Data {
        let name = "TractandaEnrollmentLocal/" + method
        let request = try JMAPValue.object([
            .init("using", .array([.string(NativePersonalEnrollment.capability)])),
            .init(
                "methodCalls",
                .array([JMAPInvocation(name: name, arguments: arguments, callID: "cluster").value])),
        ]).encoded()
        let selectedConnection = try connection()
        let response =
            try sendForTesting?(selectedConnection, request)
            ?? NativePersonalEnrollment.call(connection: selectedConnection, request: request)
        if let error = try? JSON.decode(TractandaError.self, response) { throw error }
        return try NativeMethodResult.unwrap(response, method: name, callID: "cluster")
    }
    func render(_ data: Data) throws {
        if json {
            output(data)
            return
        }
        let value = try JMAPValue.decode(data)
        var lines: [String] = []
        if let operation = value["operationID"]?.text { lines.append("Operation: " + operation) }
        if let phase = value["phase"]?.text { lines.append("Join: " + phase) }
        if let error = value["lastErrorCode"]?.text { lines.append("Current condition: " + error) }
        output(Data(lines.joined(separator: "\n").utf8))
    }
    if action == "invite" {
        var fields: [JMAPMember] = []
        if let host = values["--hostname"] { fields.append(.init("hostname", .string(host))) }
        if !fallback.isEmpty { fields.append(.init("fallbackHosts", .array(fallback.map(JMAPValue.string)))) }
        if flags.contains("--resume") { fields.append(.init("resume", .bool(true))) }
        let response = try JMAPValue.decode(call("invite", .object(fields)))
        guard let code = response["code"]?.text, let metadata = response["invitation"],
            metadata.members != nil
        else {
            throw TractandaError(
                "privateEnrollmentUnavailable",
                "The private invitation result is unavailable; use invite --resume with a private output sink."
            )
        }
        let invitation = try PersonalEnrollmentInvitation.parsePrivateCode(code)
        do {
            if let path = values["--out"] {
                try ClusterEnrollmentPrivateInput.writeInvitation(invitation, toPrivateFile: path)
            } else {
                try ClusterEnrollmentPrivateInput.writeInvitationToTerminal(invitation)
            }
        } catch {
            throw TractandaError(
                "privateEnrollmentUnavailable",
                "Code delivery failed. Use cluster invite --resume --out PRIVATE_FILE to redisplay the same still-unused invitation."
            )
        }
        if json {
            output(try metadata.encoded())
        } else {
            output(
                Data(
                    "Pairing invitation \(invitation.metadata.operationID) is ready. Enter the code on the fresh target; use invite --resume to redisplay it privately."
                        .utf8))
        }
        return true
    }
    var fields: [JMAPMember] = []
    var response: Data
    if action == "join" {
        // Limit the code's in-memory scope to submission; the daemon has already
        // persisted its independent continuation before this function begins watching.
        func submit() throws -> Data {
            let invitation: PersonalEnrollmentInvitation
            if let path = values["--code-file"] {
                invitation = try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: path)
            } else {
                invitation = try ClusterEnrollmentPrivateInput.readInvitationFromTerminal()
            }
            if let instance = values["--prepare-new"] {
                if let prepareNewForTesting {
                    preparedConnection = try prepareNewForTesting(instance, invitation.metadata)
                } else {
                    preparedConnection = try ClusterEnrollmentSetup.prepareNew(
                        instance: instance, metadata: invitation.metadata)
                }
            }
            var fields: [JMAPMember] = [
                .init("code", .string(try invitation.privateCode())),
                .init("hostname", .string(values["--hostname"]!)),
            ]
            if flags.contains("--replace-expired") { fields.append(.init("replaceExpired", .bool(true))) }
            return try call("join", .object(fields))
        }
        response = try submit()
    } else {
        if let operation = values["--operation-id"] {
            fields.append(.init("operationID", .string(operation)))
        }
        response = try call(action == "resume" ? "resume" : "status", .object(fields))
    }
    if action != "join" || flags.contains("--no-wait") {
        try render(response)
        return true
    }
    var previous: Data?
    let actionable: Set<String> = [
        "configurationDrift", "membershipConflict", "enrollmentConflict", "forbidden",
        "invalidEnrollmentTarget",
        "enrollmentCapacityUnsupported", "enrollmentTopologyUnsupported", "invitationExpired",
        "principalMappingChanged",
        "enrollmentPersistenceUncertain",
    ]
    while true {
        let value = try JMAPValue.decode(response)
        if !json, response != previous {
            try render(response)
            previous = response
        }
        if value["phase"]?.text == "complete" {
            if json { output(response) }
            return true
        }
        if let condition = value["lastErrorCode"]?.text, actionable.contains(condition) {
            throw TractandaError(
                condition,
                "Join is retained and needs attention. Resolve the condition, then use cluster resume for the same operation."
            )
        }
        Thread.sleep(forTimeInterval: 1)
        var statusFields: [JMAPMember] = []
        // Recovery may discover that an earlier operation in this bounded unused
        // family was already accepted. Follow that exact family rather than pinning
        // a rejected renewal's operation ID or silently following an unrelated job.
        if let family = value["familyID"]?.text {
            statusFields.append(.init("familyID", .string(family)))
        } else if let operation = value["operationID"]?.text {
            statusFields.append(.init("operationID", .string(operation)))
        }
        response = try call("status", .object(statusFields))
    }
}
