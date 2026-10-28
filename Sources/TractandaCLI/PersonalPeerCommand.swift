import CTractandaPlatform
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Fresh enrollment commands use explicit private files and current administrator actions.
/// Offline commands take an exclusive Store writer and never stop/start a live daemon.
func personalPeerCommand(
    _ arguments: [String], options: ConnectionOptions, hasConnectionOptions: Bool,
    sendForTesting: CLIRequestSender? = nil
) throws -> Bool {
    guard arguments.first == "personal-peer" else { return false }
    let help = """
        personal-peer target-create ROOT STORE_ID ACCESS_JSON
        personal-peer local-identity ROOT
        personal-peer local-prepare ROOT CONFIG_JSON EXPECTED_DIGEST_OR_- NONCE ACTOR
        personal-peer pair-files CONFIG_JSON LEFT_REPLICA RIGHT_REPLICA LEFT_PRIVATE_DIR RIGHT_PRIVATE_DIR
        personal-peer local-register ROOT CONFIG_JSON ACTOR CREDENTIAL_FILE...
        personal-peer local-baseline-begin ROOT SOURCE_REPLICA ACTOR
        personal-peer runtime-file CONFIG_JSON LOCAL_REPLICA PORT OUTPUT_PRIVATE_JSON [ENDPOINTS_JSON]
        [--profile NAME | --socket PATH] personal-peer identity|sync-status
        [--profile NAME | --socket PATH] personal-peer prepare CONFIG_JSON EXPECTED_DIGEST_OR_- NONCE
        [--profile NAME | --socket PATH] personal-peer register CONFIG_JSON CREDENTIAL_FILE...
        [--profile NAME | --socket PATH] personal-peer commit PREPARATION_JSON
        [--profile NAME | --socket PATH] personal-peer baseline-begin SOURCE_REPLICA
        [--profile NAME | --socket PATH] personal-peer baseline-finish SELECTION_ID
        """
    guard arguments.count >= 2 else { throw TractandaError("usage", help) }
    let operation = arguments[1]
    func require(_ count: Int) throws {
        guard arguments.count == count else { throw TractandaError("usage", help) }
    }
    func bytes(_ path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 262_145) ?? Data()
        guard bytes.count <= 262_144 else {
            throw TractandaError("resourceLimit", "Personal enrollment input exceeds 256KiB.")
        }
        return bytes
    }
    func configuration(_ path: String) throws -> PersonalMembershipConfiguration {
        let value = try JSON.decode(PersonalMembershipConfiguration.self, bytes(path))
        try value.validate()
        return value
    }
    let offline = [
        "target-create", "local-identity", "local-prepare", "pair-files", "local-register",
        "local-baseline-begin", "runtime-file",
    ].contains(operation)
    if offline {
        guard !hasConnectionOptions else {
            throw TractandaError(
                "usage", "Offline enrollment commands require explicit paths and no connection options.")
        }
        switch operation {
        case "target-create":
            try require(5)
            let access = try LocalContentRecovery.configuration(at: URL(fileURLWithPath: arguments[4]))
            let store = try ItemStore.createPersonalSyncReplica(
                root: URL(fileURLWithPath: arguments[2], isDirectory: true),
                storeID: arguments[3], accessConfiguration: access)
            output(try JSON.encode(store.personalSyncIdentity()))
        case "pair-files":
            try require(7)
            try PersonalPairingFiles.create(
                configuration: configuration(arguments[2]), leftReplicaID: arguments[3],
                rightReplicaID: arguments[4],
                leftDirectory: URL(fileURLWithPath: arguments[5], isDirectory: true),
                rightDirectory: URL(fileURLWithPath: arguments[6], isDirectory: true))
            output(try JSON.encode(["created": true]))
        case "runtime-file":
            guard arguments.count == 6 || arguments.count == 7 else {
                throw TractandaError("usage", help)
            }
            let config = try configuration(arguments[2])
            guard config.members.contains(where: { $0.replicaID == arguments[3] }),
                let port = Int(arguments[4])
            else { throw TractandaError("usage", help) }
            let overrides =
                arguments.count == 7
                ? try JSON.decode([String: [PeerRuntimeConfiguration.Endpoint]].self, bytes(arguments[6]))
                : [:]
            let peers = try PersonalPeerRuntimeConfiguration.configuredPeers(
                membership: config, localReplicaID: arguments[3], port: port, endpointOverrides: overrides)
            let settings = try PersonalPeerRuntimeConfiguration(
                settings: PeerRuntimeConfiguration(
                    listen: .init(host: "0.0.0.0", port: port), peers: peers,
                    synchronization: .init(enabled: true, intervalSeconds: 15)))
            try writePersonalRuntime(settings.encoded(), path: arguments[5])
            output(try JSON.encode(["created": true]))
        default:
            guard arguments.count >= 3 else { throw TractandaError("usage", help) }
            let store = try ItemStore.openInitialized(
                root: URL(fileURLWithPath: arguments[2], isDirectory: true))
            if operation == "local-identity" {
                try require(3)
                output(try JSON.encode(store.personalSyncIdentity()))
            } else if operation == "local-prepare" {
                try require(7)
                let actor = try SystemAccountDirectory().user(named: arguments[6]).uid
                output(
                    try JSON.encode(
                        store.preparePersonalMembershipChange(
                            configuration: configuration(arguments[3]),
                            expectedDigest: arguments[4] == "-" ? nil : arguments[4], nonce: arguments[5],
                            actorUID: actor)))
            } else if operation == "local-register" {
                guard arguments.count >= 6 else { throw TractandaError("usage", help) }
                let actor = try SystemAccountDirectory().user(named: arguments[4]).uid
                let paths = Array(arguments.dropFirst(5))
                try PersonalPairingFiles.register(
                    store: store, paths: paths, configuration: configuration(arguments[3]), actorUID: actor)
                output(try JSON.encode(["registered": paths.count]))
            } else {
                try require(5)
                let actor = try SystemAccountDirectory().user(named: arguments[4]).uid
                output(
                    try JSON.encode([
                        "selectionID": store.startPersonalBaseline(
                            sourceReplicaID: arguments[3], actorUID: actor)
                    ]))
            }
        }
        return true
    }
    var fields: [String: ItemValue] = [:]
    let action: String
    switch operation {
    case "identity", "sync-status":
        try require(2)
        action = operation == "identity" ? "identity" : "sync.status"
    case "prepare":
        try require(5)
        action = "membership.prepare"
        fields = [
            "configuration": .bytes(try JSON.encode(configuration(arguments[2]))),
            "nonce": .text(arguments[4]),
        ]
        if arguments[3] != "-" { fields["expectedDigest"] = .text(arguments[3]) }
    case "register":
        guard arguments.count >= 4 else { throw TractandaError("usage", help) }
        action = "credentials.register"
        fields = [
            "configuration": .bytes(try JSON.encode(configuration(arguments[2]))),
            "paths": .list(arguments.dropFirst(3).map(ItemValue.text)),
        ]
    case "commit":
        try require(3)
        action = "membership.commit"
        fields = ["preparation": .bytes(try bytes(arguments[2]))]
    case "baseline-begin":
        try require(3)
        action = "baseline.begin"
        fields = ["sourceReplicaID": .text(arguments[2])]
    case "baseline-finish":
        try require(3)
        action = "baseline.finish"
        fields = ["selectionID": .text(arguments[2])]
    default: throw TractandaError("usage", help)
    }
    var selected = options
    selected.startsService = false
    let request = PeerExchangeRequest(action, fields)
    let object = try JSONSerialization.jsonObject(with: JSON.encode(request))
    output(
        try call(
            selected.resolve(), "TractandaPeerPersonal/admin", object,
            responseWait: .untilCompletion, sendForTesting: sendForTesting))
    return true
}

private func writePersonalRuntime(_ bytes: Data, path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
        throw TractandaError("configurationWrite", "Runtime output must be a new private regular file.")
    }
    defer { close(fd) }
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw TractandaError("configurationWrite", "Cannot write personal runtime output.")
            }
            offset += count
        }
    }
    guard fsync(fd) == 0 else {
        throw TractandaError("configurationWrite", "Cannot synchronize personal runtime output.")
    }
}
