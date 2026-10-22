import Foundation
import XCTest

@testable import TractandaSetup

final class SetupServiceBackendTests: XCTestCase {
    final class Runner: SetupProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var loadState = "loaded", activeState = "inactive", dropIns = "", enabled = "disabled"
        var needsReload = false
        var pid: Int32 = 0
        var fragment: String
        var failStart = false, failDisable = false, failEnableAfterMutation = false, staysRunning = false
        init(fragment: String = "/etc/systemd/system/tractanda-server-production.service") {
            self.fragment = fragment
        }
        func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws
            -> ProcessResult
        {
            calls.append((executable, arguments))
            guard executable == "/usr/bin/systemctl" else { return ProcessResult(status: 1) }
            switch arguments.first {
            case "show":
                return ProcessResult(
                    status: loadState == "not-found" ? 1 : 0,
                    output:
                        "LoadState=\(loadState)\nActiveState=\(activeState)\nFragmentPath=\(fragment)\nDropInPaths=\(dropIns)\nNeedDaemonReload=\(needsReload ? "yes" : "no")\nMainPID=\(pid)\nUnitFileState=\(enabled)\n"
                )
            case "enable":
                enabled = "enabled"
                if failEnableAfterMutation {
                    return ProcessResult(status: 1, output: "fixture partial enable failure")
                }
            case "start":
                if failStart { return ProcessResult(status: 1, output: "fixture execution failure") }
                activeState = "active"
                pid = 4242
            case "stop":
                if !staysRunning {
                    activeState = "inactive"
                    pid = 0
                }
            case "disable":
                if failDisable { return ProcessResult(status: 1, output: "fixture disable failure") }
                enabled = "disabled"
                activeState = "inactive"
                pid = 0
            case "daemon-reload": needsReload = false
            default: return ProcessResult(status: 1)
            }
            return ProcessResult(status: 0)
        }
    }
    private func backend(_ runner: Runner) -> SetupServiceBackend {
        SetupServiceBackend(roots: SetupRoots(platform: .linux), runner: runner)
    }

    func testLinuxRootsAndDaemonFollowAcceptedPOCPolicy() {
        let roots = SetupRoots(platform: .linux)
        XCTAssertEqual(roots.platform.serviceUser, "daemon")
        XCTAssertEqual(roots.runtime.path, "/run/tractanda")
        XCTAssertEqual(roots.commands.path, "/usr/bin")
        XCTAssertEqual(roots.data.path, "/var/lib/tractanda/stores")
        XCTAssertEqual(roots.indexes.path, "/var/cache/tractanda/indexes")
    }

    func testServerUnitLiteralArgumentsAndTrustedEnvironmentHaveNoShell() throws {
        let manager = backend(Runner())
        let bytes = try manager.systemdDefinition(
            instance: "production", role: .server,
            arguments: ["/opt/tractanda/current/bin/tractanda", "daemon", "/var/lib/a b/\"q\"\\x%t$HOME"],
            environment: ["TRACTANDA_UUID_NODE": "00:01:02:03:04:05", "VALUE": "$HOME%t"])
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("User=daemon\n"))
        XCTAssertTrue(text.contains("Type=exec\n"))
        XCTAssertTrue(text.contains("\"/var/lib/a b/\\\"q\\\"\\\\x%%t$$HOME\""))
        XCTAssertTrue(text.contains("Environment=\"VALUE=$HOME%%t\""))
        XCTAssertTrue(text.contains("RuntimeDirectory=tractanda/production\nRuntimeDirectoryMode=0711"))
        XCTAssertFalse(text.contains("/bin/sh"))
        XCTAssertFalse(text.contains("User=root"))
    }

    func testUnitRejectsControlsUnsafeInstanceEnvironmentAndRuntimeRoot() throws {
        let manager = backend(Runner())
        for argument in ["a\nb", "a\rb", "a\0b", "a\tb"] {
            XCTAssertThrowsError(
                try manager.systemdDefinition(
                    instance: "production", role: .server,
                    arguments: ["/bin/true", argument]))
        }
        for instance in ["", "a/b", "a.service\nUser=root", "a%t", "../x"] {
            XCTAssertThrowsError(
                try manager.systemdDefinition(
                    instance: instance, role: .embeddings,
                    arguments: ["/bin/true"]))
        }
        XCTAssertThrowsError(
            try manager.systemdDefinition(
                instance: "production", role: .server,
                arguments: ["/bin/true"], environment: ["1KEY": "value"]))
        let changed = SetupServiceBackend(
            roots: SetupRoots(
                platform: .linux,
                runtime: URL(fileURLWithPath: "/tmp/arbitrary")), runner: Runner())
        XCTAssertThrowsError(
            try changed.systemdDefinition(instance: "production", role: .server, arguments: ["/bin/true"]))
    }

    func testBrokerUnitIsFixedRootHelperAndEmbeddingUnitRemainsUnprivileged() throws {
        let manager = backend(Runner())
        let broker = String(
            decoding: try manager.authenticationDefinition(instance: "production"), as: UTF8.self)
        XCTAssertTrue(broker.contains("User=root\n"))
        XCTAssertTrue(
            broker.contains(
                "\"/opt/tractanda/current/bin/tractanda-auth-helper\" \"--socket\" \"/run/tractanda-auth-production/auth.sock\" \"--allowed-user\" \"daemon\""
            ))
        XCTAssertTrue(
            broker.contains("RuntimeDirectory=tractanda-auth-production\nRuntimeDirectoryMode=0755"))
        XCTAssertTrue(broker.contains("LimitCORE=0"))
        let embedding = String(
            decoding: try manager.systemdDefinition(
                instance: "production", role: .embeddings,
                arguments: [
                    "/opt/tractanda/current/bin/tractanda-embeddings", "--model",
                    "/opt/tractanda/current/models/pinned",
                ]), as: UTF8.self)
        XCTAssertTrue(embedding.contains("User=daemon\n"))
        XCTAssertFalse(embedding.contains("RuntimeDirectory="))
    }

    func testStartReloadsChecksEnablesAndVerifiesActualManagerState() throws {
        let runner = Runner()
        let service = backend(runner)
        try service.load("production")
        XCTAssertEqual(
            runner.calls.map { $0.1.first! }, ["daemon-reload", "show", "enable", "start", "show"])
        XCTAssertTrue(runner.calls.allSatisfy { $0.0 == "/usr/bin/systemctl" && !$0.1.contains("--user") })
        XCTAssertTrue(try service.isRunning("production"))
        XCTAssertEqual(try service.mainPID("production", role: .server), 4242)
    }

    func testForeignFragmentOrDropInRefusesStartStopAndBootMutation() throws {
        for foreignFragment in [false, true] {
            let runner = Runner()
            if foreignFragment {
                runner.fragment = "/etc/systemd/system/foreign.service"
            } else {
                runner.dropIns = "/etc/systemd/system/tractanda-server-production.service.d/override.conf"
            }
            let service = backend(runner)
            XCTAssertThrowsError(try service.load("production"))
            XCTAssertThrowsError(try service.unload("production"))
            XCTAssertThrowsError(try service.disable("production"))
            XCTAssertFalse(
                runner.calls.contains { ["enable", "start", "stop", "disable"].contains($0.1.first!) })
        }
    }

    func testFailedStartDisablesBootAndLeavesStoppedWithoutOldProgramRestart() throws {
        let runner = Runner()
        runner.failStart = true
        XCTAssertThrowsError(try backend(runner).load("production"))
        XCTAssertEqual(runner.enabled, "disabled")
        XCTAssertEqual(runner.activeState, "inactive")
        XCTAssertEqual(runner.calls.filter { $0.1.first == "start" }.count, 1)
        XCTAssertTrue(
            runner.calls.contains { $0.1 == ["disable", "--now", "tractanda-server-production.service"] })
    }

    func testPartialEnableFailureDisablesBootAndReportsFailedCleanup() throws {
        let runner = Runner()
        runner.failEnableAfterMutation = true
        XCTAssertThrowsError(try backend(runner).load("production"))
        XCTAssertEqual(runner.enabled, "disabled")
        XCTAssertFalse(runner.calls.contains { $0.1.first == "start" })
        let blocked = Runner()
        blocked.failEnableAfterMutation = true
        blocked.failDisable = true
        XCTAssertThrowsError(try backend(blocked).load("production")) { error in
            XCTAssertTrue(error.localizedDescription.contains("boot disablement could not be verified"))
        }
        XCTAssertEqual(blocked.enabled, "enabled")  // The error must not pretend cleanup succeeded.
    }

    func testStoppedOrFailedUnitWithMainPIDCannotProveQuiescence() throws {
        for state in ["inactive", "failed"] {
            let runner = Runner()
            runner.activeState = state
            runner.pid = 4242
            XCTAssertThrowsError(try backend(runner).isRunning("production"))
            XCTAssertThrowsError(try backend(runner).mainPID("production", role: .server))
        }
    }

    func testStopMustProveNoMainProcessAndDisableMustProvePersistentState() throws {
        let runner = Runner()
        runner.activeState = "active"
        runner.pid = 4242
        runner.staysRunning = true
        XCTAssertThrowsError(try backend(runner).unload("production"))
        runner.failDisable = true
        XCTAssertThrowsError(try backend(runner).disable("production"))
        XCTAssertEqual(runner.pid, 4242)
        runner.failDisable = false
        try backend(runner).disable("production")
        XCTAssertEqual(runner.enabled, "disabled")
        XCTAssertEqual(runner.pid, 0)
    }

    func testInactiveUnloadedTransitionalAndManagerErrorsAreNotInterchangeable() throws {
        let runner = Runner()
        let manager = backend(runner)
        runner.needsReload = true
        XCTAssertThrowsError(try manager.isRunning("production"))
        runner.needsReload = false
        runner.activeState = "deactivating"
        XCTAssertThrowsError(try manager.isRunning("production"))
        runner.loadState = "not-found"
        runner.activeState = "inactive"
        runner.fragment = ""
        XCTAssertFalse(try manager.isRunning("production"))
        runner.pid = 4242
        XCTAssertThrowsError(try manager.isRunning("production"))
    }

    func testStatusParserFailsClosedOnIncompleteDuplicateOversizedOrInvalidStatus() throws {
        let runner = Runner()
        let valid = try runner.run("/usr/bin/systemctl", ["show"], environment: [:]).output
        XCTAssertNoThrow(try SetupSystemdState(output: valid))
        XCTAssertThrowsError(try SetupSystemdState(output: valid + "MainPID=3\n"))
        XCTAssertThrowsError(
            try SetupSystemdState(output: valid.replacingOccurrences(of: "MainPID=0\n", with: "")))
        XCTAssertThrowsError(
            try SetupSystemdState(output: valid.replacingOccurrences(of: "MainPID=0", with: "MainPID=-1")))
        XCTAssertThrowsError(try SetupSystemdState(output: String(repeating: "x", count: 16_385)))
    }

    func testMacBackendRetainsExistingLaunchctlNamesAndCalls() throws {
        final class MacRunner: SetupProcessRunning, @unchecked Sendable {
            var calls: [(String, [String])] = []
            var loaded = false
            func run(_ executable: String, _ arguments: [String], environment: [String: String])
                -> ProcessResult
            {
                calls.append((executable, arguments))
                if executable == "/bin/ps" {
                    return ProcessResult(
                        status: loaded ? 0 : 1, output: loaded ? "Thu Oct 22 12:00:00 2026 S\n" : "")
                }
                if arguments.first == "print" {
                    return ProcessResult(status: loaded ? 0 : 1, output: "pid = 4242\n")
                }
                if arguments.first == "bootstrap" { loaded = true }
                if arguments.first == "bootout" { loaded = false }
                return ProcessResult(status: 0)
            }
        }
        let runner = MacRunner()
        let manager = SetupServiceBackend(roots: SetupRoots(platform: .macos), runner: runner)
        XCTAssertEqual(manager.label("production"), "system/ai.tractanda.server.production")
        try manager.load("production")
        XCTAssertEqual(try manager.mainPID("production", role: .server), 4242)
        try manager.unload("production")
        XCTAssertFalse(runner.loaded)
        XCTAssertTrue(runner.calls.allSatisfy { ["/bin/launchctl", "/bin/ps"].contains($0.0) })
    }
    func testMacBootoutWaitsForCapturedIncarnationIncludingSlowExitAndZombie() throws {
        final class DrainRunner: SetupProcessRunning, @unchecked Sendable {
            var bootedOut = false
            var probes = 0
            var endWithZombie = false
            func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws
                -> ProcessResult
            {
                if executable == "/bin/launchctl" {
                    if arguments.first == "bootout" {
                        bootedOut = true
                        return .init(status: 0)
                    }
                    return .init(status: 0, output: "pid = 4242\n")
                }
                XCTAssertEqual(executable, "/bin/ps")
                if bootedOut {
                    probes += 1
                    if probes == 1 { throw SetupProcessTimeout(message: "fixture bounded status timeout") }
                    if probes > 3 {
                        return .init(
                            status: endWithZombie ? 0 : 1,
                            output: endWithZombie ? "Thu Oct 22 12:00:00 2026 Z\n" : "")
                    }
                }
                return .init(status: 0, output: "Thu Oct 22 12:00:00 2026 S\n")
            }
        }
        for role in [SetupServiceRole.server, .embeddings] {
            let runner = DrainRunner()
            runner.endWithZombie = role == .embeddings
            var backend = SetupServiceBackend(roots: SetupRoots(platform: .macos), runner: runner)
            var virtualElapsed = 0.0
            backend.shutdownSleep = { virtualElapsed += 3600 }  // Slow healthy shutdown exceeds two hours.
            backend.shutdownReport = { _ in }
            try backend.unload("production", role: role)
            XCTAssertTrue(runner.bootedOut)
            XCTAssertEqual(runner.probes, 4)
            XCTAssertGreaterThan(virtualElapsed, 7200)
        }
    }

}
