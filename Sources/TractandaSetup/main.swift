import Foundation
import TractandaCore

let usage = """
    Usage: tractanda-setup plan|install|upgrade|status|start|stop|restart|uninstall [options]

    Options: --bundle PATH --name NAME --owner OS_USER --empty|--sample --port PORT
             --data-root PATH --index-root PATH --uuid-node MAC
    """

func printJSON<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func parse() throws -> (String, SetupOptions, URL?, URL?) {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw SetupError(usage) }
    args.removeFirst()
    var name = "default"
    var owner: String?
    var mode: SetupOptions.Mode = .empty
    var port = 48_728
    var bundle = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .deletingLastPathComponent()
    var dataRoot: URL?
    var indexRoot: URL?
    var node: String?
    while let flag = args.first {
        args.removeFirst()
        switch flag {
        case "--name", "--owner", "--bundle", "--port", "--data-root", "--index-root", "--uuid-node":
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
            default: node = value
            }
        case "--sample": mode = .sample
        case "--empty": mode = .empty
        default: throw SetupError("Unknown option: \(flag)")
        }
    }
    return (
        command,
        SetupOptions(name: name, owner: owner, mode: mode, port: port, bundle: bundle, uuidNode: node),
        dataRoot, indexRoot
    )
}

do {
    let internalArguments = Array(CommandLine.arguments.dropFirst())
    if internalArguments.contains("--help") {
        print(usage)
        exit(0)
    }
    if internalArguments.first == "--bootstrap-store" {
        guard SetupPlatform.host == .macos, internalArguments.count == 5,
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
    FileHandle.standardError.write(Data("tractanda-setup: \(error.localizedDescription)\n".utf8))
    exit(1)
}
