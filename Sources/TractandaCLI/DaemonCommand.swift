import CTractandaPlatform
import Foundation
import TractandaClient
import TractandaServer

func daemonCommand(_ arguments: [String]) async throws {
    if arguments == ["daemon", "--help"] {
        print(usage)
        return
    }
    guard arguments.count >= 3 else { throw TractandaError("usage", usage) }
    let store = arguments[1]
    let socket = arguments[2]
    var port: Int? = 48_728
    var managed = false
    var view: String?
    var projectRoot: String?
    var statusRoot: String?
    var project: String?
    var indexDirectory: String?
    var seen: Set<String> = []
    var index = 3
    while index < arguments.count {
        let flag = arguments[index]
        switch flag {
        case "--no-http":
            guard !seen.contains("http"), port != nil else { throw TractandaError("usage", usage) }
            seen.insert("http")
            port = nil
            index += 1
        case "--managed":
            guard !managed else { throw TractandaError("usage", usage) }
            managed = true
            index += 1
        case "--http-port", "--view", "--project-root", "--status-root", "--project", "--index-directory":
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw TractandaError("usage", usage)
            }
            let value = arguments[index + 1]
            switch flag {
            case "--http-port":
                guard !seen.contains("http"), port != nil, let parsed = Int(value),
                    (0...65535).contains(parsed)
                else {
                    throw TractandaError("usage", usage)
                }
                seen.insert("http")
                port = parsed
            case "--view":
                guard view == nil else { throw TractandaError("usage", usage) }
                view = value
            case "--project-root":
                guard projectRoot == nil else { throw TractandaError("usage", usage) }
                projectRoot = value
            case "--status-root":
                guard statusRoot == nil else { throw TractandaError("usage", usage) }
                statusRoot = value
            case "--index-directory":
                guard indexDirectory == nil else { throw TractandaError("usage", usage) }
                indexDirectory = value
            default:
                guard project == nil else { throw TractandaError("usage", usage) }
                project = value
            }
            index += 2
        default: throw TractandaError("usage", usage)
        }
    }
    let configuration = DaemonConfiguration(
        storePath: store, indexDirectory: indexDirectory, socketPath: socket, httpPort: port,
        managed: managed, viewItemID: view,
        projectRootID: projectRoot, statusRootID: statusRoot, initialProjectID: project)
    guard tractanda_start_signals() == 0 else {
        throw TractandaError("signal", "Cannot install shutdown signals.")
    }
    defer { tractanda_restore_signals() }
    let startupWatchdog = Task.detached {
        while !Task.isCancelled && tractanda_stopping() == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled, tractanda_stopping() != 0 else { return }
        do {
            try await Task.sleep(for: .seconds(2))
        } catch { return }
        guard !Task.isCancelled else { return }
        // Only the C startup guard can restore default SIGTERM handling. It is cleared before
        // the daemon advertises endpoints, so normal serving writes keep coordinated shutdown.
        _ = tractanda_terminate_if_stopping()
    }
    tractanda_startup_shutdown_guard_begin()
    let daemon: SharedDaemon
    do {
        daemon = try await SharedDaemon.start(
            configuration: configuration,
            claimStartupReadiness: { tractanda_startup_shutdown_guard_ready() != 0 })
    } catch {
        tractanda_startup_shutdown_guard_end()
        startupWatchdog.cancel()
        throw error
    }
    tractanda_startup_shutdown_guard_end()
    startupWatchdog.cancel()
    do {
        if tractanda_stopping() != 0 {
            await daemon.close()
            return
        }
        output(try JSONEncoder().encode(await daemon.endpoints()))
        while tractanda_stopping() == 0 { try await Task.sleep(for: .milliseconds(100)) }
        await daemon.close()
    } catch {
        await daemon.close()
        throw error
    }
}
