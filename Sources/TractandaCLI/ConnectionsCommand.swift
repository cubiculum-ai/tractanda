import Foundation
import TractandaCore

func handleConnectionCommand(_ arguments: [String]) throws -> Bool {
    guard let command = arguments.first, ["connections", "service"].contains(command) else { return false }
    let usage = """
        tractanda connections list
        tractanda connections add NAME SOCKET [--server-user USER] [--default]
        tractanda connections default|remove NAME
        tractanda service prepare|install NAME STORE [--socket PATH] [--default]
            [--shared [--http-port PORT|--no-http]
             [--view ID | --project-root ID --status-root ID [--project ID]]]
        tractanda service activate NAME [--default]
        tractanda service start|stop|status|uninstall NAME
        """
    guard arguments.count >= 2 else { throw TractandaError("usage", usage) }
    let operation = arguments[1]
    let preferences = ConnectionPreferences()
    if command == "connections" {
        if operation == "list", arguments.count == 2 {
            output(try JSON.encode(preferences.loadEffective()))
            return true
        }
        guard arguments.count >= 3 else { throw TractandaError("usage", usage) }
        let name = arguments[2]
        try ConnectionPreferences.validateName(name)
        switch operation {
        case "add":
            guard arguments.count >= 4 else { throw TractandaError("usage", usage) }
            var connection = ServerConnection(
                socketPath: URL(fileURLWithPath: arguments[3]).standardizedFileURL.path)
            var makeDefault = false
            var remaining = Array(arguments.dropFirst(4))
            while let flag = remaining.first {
                remaining.removeFirst()
                if flag == "--default" {
                    makeDefault = true
                } else if flag == "--server-user", let account = remaining.first {
                    connection.serverUser = account
                    remaining.removeFirst()
                } else {
                    throw TractandaError("usage", usage)
                }
            }
            try preferences.update {
                $0.profiles[name] = connection
                if makeDefault || $0.defaultProfile == nil { $0.defaultProfile = name }
            }
        case "default" where arguments.count == 3:
            try preferences.update { $0.defaultProfile = name }
        case "remove" where arguments.count == 3:
            try preferences.update {
                guard $0.profiles.removeValue(forKey: name) != nil else {
                    throw TractandaError("unknownProfile", "Unknown profile: \(name)")
                }
                if $0.defaultProfile == name { $0.defaultProfile = nil }
            }
        default: throw TractandaError("usage", usage)
        }
        output(try JSON.encode(preferences.loadEffective()))
        return true
    }
    guard arguments.count >= 3 else { throw TractandaError("usage", usage) }
    let name = arguments[2]
    switch operation {
    case "prepare", "install":
        guard arguments.count >= 4 else { throw TractandaError("usage", usage) }
        var socket: String?
        var makeDefault = false
        var shared = false
        var httpPort: Int? = 48_728
        var httpModeSet = false
        var view: String?
        var projectRoot: String?
        var statusRoot: String?
        var project: String?
        var remaining = Array(arguments.dropFirst(4))
        while let flag = remaining.first {
            remaining.removeFirst()
            if flag == "--default" {
                guard !makeDefault else { throw TractandaError("usage", usage) }
                makeDefault = true
            } else if flag == "--socket", let value = remaining.first, !value.hasPrefix("--") {
                guard socket == nil else { throw TractandaError("usage", usage) }
                socket = URL(fileURLWithPath: value).standardizedFileURL.path
                remaining.removeFirst()
            } else if flag == "--shared" {
                guard !shared else { throw TractandaError("usage", usage) }
                shared = true
            } else if flag == "--no-http" {
                guard !httpModeSet else { throw TractandaError("usage", usage) }
                httpModeSet = true
                httpPort = nil
            } else if ["--http-port", "--view", "--project-root", "--status-root", "--project"].contains(
                flag),
                let value = remaining.first, !value.hasPrefix("--")
            {
                remaining.removeFirst()
                switch flag {
                case "--http-port":
                    guard !httpModeSet, let port = Int(value), (0...65_535).contains(port) else {
                        throw TractandaError("usage", usage)
                    }
                    httpModeSet = true
                    httpPort = port
                case "--view":
                    guard view == nil else { throw TractandaError("usage", usage) }
                    view = value
                case "--project-root":
                    guard projectRoot == nil else { throw TractandaError("usage", usage) }
                    projectRoot = value
                case "--status-root":
                    guard statusRoot == nil else { throw TractandaError("usage", usage) }
                    statusRoot = value
                default:
                    guard project == nil else { throw TractandaError("usage", usage) }
                    project = value
                }
            } else {
                throw TractandaError("usage", usage)
            }
        }
        guard
            shared
                || (!httpModeSet && view == nil && projectRoot == nil && statusRoot == nil && project == nil),
            (projectRoot == nil) == (statusRoot == nil), project == nil || projectRoot != nil,
            !(view != nil && projectRoot != nil)
        else { throw TractandaError("usage", usage) }
        let daemon =
            shared
            ? ManagedServer.SharedDaemonOptions(
                httpPort: httpPort, viewItemID: view, projectRootID: projectRoot,
                statusRootID: statusRoot, initialProjectID: project)
            : nil
        let record = try ManagedServer.prepare(
            name: name, store: URL(fileURLWithPath: arguments[3]),
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),
            socketPath: socket, sharedDaemon: daemon)
        if operation == "install" { try ManagedServer.install(name: name, makeDefault: makeDefault) }
        output(try JSON.encode(record))
    case "activate" where arguments.count == 3 || arguments == ["service", "activate", name, "--default"]:
        try ManagedServer.install(name: name, makeDefault: arguments.last == "--default")
        output(try JSON.encode(ManagedServer.registration(name: name)))
    case "start" where arguments.count == 3, "stop" where arguments.count == 3,
        "status" where arguments.count == 3, "uninstall" where arguments.count == 3:
        switch operation {
        case "start": try ManagedServer.start(name: name)
        case "stop": try ManagedServer.stop(name: name)
        case "uninstall": try ManagedServer.uninstall(name: name)
        default:
            output(try JSON.encode(["name": name, "status": try ManagedServer.status(name: name)]))
            return true
        }
        output(try JSON.encode(["name": name, "operation": operation]))
    default: throw TractandaError("usage", usage)
    }
    return true
}
