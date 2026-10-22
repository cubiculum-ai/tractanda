import CTractandaPlatform
import Foundation
import TractandaCore

let usage = """
    Usage: tractanda-setup plan|install|upgrade|status|start|stop|restart|uninstall [options]

    Options: --bundle PATH --name NAME --owner OS_USER --empty|--sample --port PORT
             --data-root PATH --index-root PATH --uuid-node MAC
             --peer-runtime-configuration INPUT_JSON | --disable-peer-runtime (plan|install|upgrade only)
             Linux install: --first-source | --adopt-prepared --store-id UUID --replica-id UUID
    """

func printJSON<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func parse() throws -> (String, SetupOptions, URL?, URL?) {
    var args = Array(CommandLine.arguments.dropFirst())
    let peerRuntimeArguments = try SetupPeerRuntimeArguments.parse(args)
    args = peerRuntimeArguments.remainingArguments
    guard let command = args.first else { throw SetupError(usage) }
    args.removeFirst()
    var name = "default"
    var owner: String?
    var mode: SetupOptions.Mode = .empty
    var port = 48_728
    var bundle =
        SetupPlatform.host == .linux
        ? SetupRoots(platform: .linux).software.appendingPathComponent("current")
        : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .deletingLastPathComponent()
    var dataRoot: URL?
    var indexRoot: URL?
    var node: String?
    var selection: String?
    var selectedStore: String?
    var selectedReplica: String?
    while let flag = args.first {
        args.removeFirst()
        switch flag {
        case "--name", "--owner", "--bundle", "--port", "--data-root", "--index-root", "--uuid-node",
            "--store-id", "--replica-id":
            guard let value = args.first else { throw SetupError("Missing value for \(flag).") }
            args.removeFirst()
            switch flag {
            case "--name": name = value
            case "--owner": owner = value
            case "--bundle": bundle = URL(fileURLWithPath: value, isDirectory: true)
            case "--port":
                guard let parsed = Int(value) else { throw SetupError("Port must be numeric.") }
                port = parsed
            case "--data-root": dataRoot = URL(fileURLWithPath: value, isDirectory: true)
            case "--index-root": indexRoot = URL(fileURLWithPath: value, isDirectory: true)
            case "--store-id":
                guard selectedStore == nil else { throw SetupError("Duplicate store pin.") }
                selectedStore = value
            case "--replica-id":
                guard selectedReplica == nil else { throw SetupError("Duplicate replica pin.") }
                selectedReplica = value
            default: node = value
            }
        case "--first-source", "--adopt-prepared":
            guard selection == nil else { throw SetupError("Choose exactly one Linux store selection.") }
            selection = flag
        case "--sample": mode = .sample
        case "--empty": mode = .empty
        default: throw SetupError("Unknown option: \(flag)")
        }
    }
    let storeSelection: SetupOptions.StoreSelection
    if selection == "--adopt-prepared" {
        guard let selectedStore, let selectedReplica else {
            throw SetupError("Prepared adoption needs independent --store-id and --replica-id UUIDv1 pins.")
        }
        storeSelection = .prepared(storeID: selectedStore, replicaID: selectedReplica)
    } else {
        guard selectedStore == nil, selectedReplica == nil else {
            throw SetupError("Identity pins require --adopt-prepared.")
        }
        storeSelection = selection == "--first-source" ? .standalone : .unconfigured
    }
    if selection != nil, !["plan", "install", "upgrade"].contains(command) {
        throw SetupError("Store selection applies only to explicit plan/install/upgrade.")
    }
    return (
        command,
        SetupOptions(
            name: name, owner: owner, mode: mode, port: port, bundle: bundle, uuidNode: node,
            peerRuntime: peerRuntimeArguments.action, storeSelection: storeSelection),
        dataRoot, indexRoot
    )
}

do {
    let internalArguments = Array(CommandLine.arguments.dropFirst())
    if internalArguments.contains("--help") {
        print(usage)
        exit(0)
    }
    if let package = try SetupPackageArguments.parse(internalArguments) {
        print(try SetupEngine().packageLifecycle(package))
        exit(0)
    }
    if internalArguments.first == "--verify-prepared-target" {
        guard internalArguments.count == 5, getuid() != 0, getuid() == tractanda_uid(),
            getuid() == (try SystemAccountDirectory().user(named: SetupPlatform.host.serviceUser)).uid
        else {
            throw SetupError("Prepared target inspection requires the existing non-root service custodian.")
        }
        try ItemStore.verifyPreparedReplicaForSetup(
            root: URL(fileURLWithPath: internalArguments[1]),
            indexDirectory: URL(fileURLWithPath: internalArguments[2]), expectedStoreID: internalArguments[3],
            expectedReplicaID: internalArguments[4])
        print("Prepared target identity, activation and authority-aware opening verified.")
        exit(0)
    }
    if internalArguments == ["--canonical-format-support"] {
        try printJSON(CanonicalFormatSupport.current)
        exit(0)
    }
    if internalArguments.first == "--canonical-reader-admit", internalArguments.count == 2 {
        let root = URL(fileURLWithPath: internalArguments[1]).resolvingSymlinksInPath()
        try printJSON(
            CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: getuid()) {
                try CanonicalReaderRequirement.admitQuiescent(root: root, ownerUID: getuid())
            })
        exit(0)
    }
    if let target = try PeerTargetActivationArguments.parse(internalArguments) {
        guard getuid() != 0, getuid() == tractanda_uid() else {
            throw SetupError("Finite target activation requires matching non-root real/effective custody.")
        }
        guard tractanda_start_signals() == 0 else {
            throw SetupError("Cannot install finite target cancellation handlers.")
        }
        // Process-global handlers belong to this standalone command exactly once.
        do {
            defer { tractanda_restore_signals() }
            try PeerTargetEnrollment.run(
                root: URL(fileURLWithPath: target.root), pin: target.pin,
                inputFD: STDIN_FILENO, outputFD: STDOUT_FILENO)
        }
        exit(0)
    }
    if internalArguments.first == "--prepare-peer-target" {
        guard internalArguments.count == 4 else {
            throw SetupError(
                "Use --prepare-peer-target ROOT STORE_UUID SOURCE_REPLICA_UUID as the existing service user.")
        }
        // The finite helper also requires effective UID == this real UID != 0.
        // OS invocation selects custody; this is never a canonical administrator claim.
        let uid = getuid()
        let preparation = try PeerTargetPreparation.run(
            root: internalArguments[1], commonStoreID: internalArguments[2],
            sourceReplicaID: internalArguments[3], requiredOwnerUID: uid)
        FileHandle.standardOutput.write(preparation)
        exit(0)
    }
    if internalArguments.first == "--bootstrap-store" {
        guard internalArguments.count == 5, getuid() != 0, getuid() == tractanda_uid(),
            getuid() == (try SystemAccountDirectory().user(named: SetupPlatform.host.serviceUser)).uid
        else { throw SetupError("Store initialization must run as the service account.") }
        try StoreBootstrap.initialize(
            store: URL(fileURLWithPath: internalArguments[1]),
            indexDirectory: URL(fileURLWithPath: internalArguments[2]),
            owner: internalArguments[3], instance: internalArguments[4])
        exit(0)
    }
    let (command, options, dataRoot, indexRoot) = try parse()
    let base = SetupRoots()
    let roots = SetupRoots(platform: base.platform, data: dataRoot, indexes: indexRoot)
    let waitsForStartup = ["install", "upgrade", "start", "restart"].contains(command)
    if waitsForStartup {
        guard tractanda_start_signals() == 0 else {
            throw SetupError("Cannot install startup cancellation handlers.")
        }
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        sigaddset(&unblocked, SIGINT)
        sigaddset(&unblocked, SIGTERM)
        pthread_sigmask(SIG_UNBLOCK, &unblocked, nil)
    }
    defer { if waitsForStartup { tractanda_restore_signals() } }
    let engine = SetupEngine(roots: roots)
    switch command {
    case "plan", "dry-run": try printJSON(engine.plan(options))
    case "install": try engine.install(options)
    case "upgrade": try engine.install(options, upgrade: true)
    case "status": print(try engine.status(options))
    case "start": try engine.start(options)
    case "stop": try engine.stop(options)
    case "restart": try engine.restart(options)
    case "uninstall": try engine.uninstall(options)
    default: throw SetupError(usage)
    }
} catch {
    let message = (error as? TractandaError)?.description ?? String(describing: error)
    FileHandle.standardError.write(Data("tractanda-setup: \(message)\n".utf8))
    exit(1)
}
