import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

final class DocumentWorkerProtocolTests: XCTestCase {
    private func bytes(_ name: String, activeIdentity: Bool = true) throws -> Data {
        let fixtures = try XCTUnwrap(
            Bundle.module.url(
                forResource: "NativeDocumentWorker", withExtension: nil, subdirectory: "Fixtures"))
        let frozen = try Data(contentsOf: fixtures.appendingPathComponent(name))
        guard activeIdentity else { return frozen }
        // The frozen vectors describe the common wire schema with the Mac identity.
        // Change only that identity literal so active-worker tests reach the wire guards
        // on Linux too; malformed fields and all other frozen bytes stay unchanged.
        let text = try XCTUnwrap(String(data: frozen, encoding: .utf8))
        return Data(
            text.replacingOccurrences(
                of: "\"converter\":\"tractanda.docling-native.v2-idefics3-gelu-f32\"",
                with: "\"converter\":\"\(DocumentConverterIdentity().converter)\""
            ).utf8)
    }

    func testPlatformCurrentBindingPreservesFrozenIdentityAdmission() throws {
        let frozen = try bytes("binding.json", activeIdentity: false)
        let retained = try JSONDecoder().decode(NativeDocumentBinding.self, from: frozen)
        XCTAssertNoThrow(try retained.identity.validate(), "The frozen Mac identity remains readable")
        #if os(Linux)
            XCTAssertThrowsError(try NativeWorkerProtocol.binding(frozen)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "unsupportedDocumentConverter")
            }
        #else
            XCTAssertNoThrow(try NativeWorkerProtocol.binding(frozen))
        #endif
        let active = try NativeWorkerProtocol.binding(bytes("binding.json"))
        XCTAssertEqual(active.identity, DocumentConverterIdentity())
    }
    func testFrozenPositiveAndNegativeWireFixturesMatchCoreIndependently() throws {
        let binding = try NativeWorkerProtocol.binding(bytes("binding.json"))
        let convert = try NativeWorkerProtocol.request(
            bytes("request-convert.json"), binding: binding, previousID: 0, pageCount: 128)
        let close = try NativeWorkerProtocol.request(
            bytes("request-close.json"), binding: binding, previousID: 1, pageCount: 128)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes("FIXTURES.json")) as? [String: Any])
        for name in try XCTUnwrap(list["positive"] as? [String]) where name.hasPrefix("response-") {
            let request =
                name == "response-hello.json" || name == "response-error.json"
                ? nil : name == "response-closed.json" ? close : convert
            XCTAssertNoThrow(
                try NativeWorkerProtocol.validateResponse(
                    bytes(name), binding: binding, outstanding: request, pageCount: 128), name)
        }
        for fixture in try XCTUnwrap(list["negative"] as? [[String: String]]) {
            let name = try XCTUnwrap(fixture["file"])
            if name.contains("binding") {
                XCTAssertThrowsError(try NativeWorkerProtocol.binding(bytes(name)), name)
            } else if name.contains("request") || name.contains("close") {
                XCTAssertThrowsError(
                    try NativeWorkerProtocol.request(
                        bytes(name), binding: binding, previousID: 0, pageCount: 128), name)
            } else {
                XCTAssertThrowsError(
                    try NativeWorkerProtocol.validateResponse(
                        bytes(name), binding: binding, outstanding: convert, pageCount: 128), name)
            }
        }
        for name in ["wrong-session-request.json", "wrong-source-response.json", "wrong-page-response.json"] {
            if name.contains("request") {
                XCTAssertThrowsError(
                    try NativeWorkerProtocol.request(
                        bytes(name), binding: binding, previousID: 0, pageCount: 128))
            } else {
                XCTAssertThrowsError(
                    try NativeWorkerProtocol.validateResponse(
                        bytes(name), binding: binding, outstanding: convert, pageCount: 128))
            }
        }
    }
    func testDecodedDuplicateEscapesUTF8TrailingValuesAndControlBoundsReject() throws {
        let binding = try NativeWorkerProtocol.binding(bytes("binding.json"))
        let hello = try XCTUnwrap(String(data: bytes("response-hello.json"), encoding: .utf8))
        let duplicate = hello.replacingOccurrences(
            of: "\"type\":\"hello\"", with: "\"type\":\"hello\",\"\\u0074ype\":\"hello\"")
        XCTAssertThrowsError(
            try NativeWorkerProtocol.validateResponse(
                Data(duplicate.utf8), binding: binding, outstanding: nil, pageCount: 128))
        XCTAssertThrowsError(
            try NativeWorkerProtocol.validateResponse(
                Data((hello + "{}").utf8), binding: binding, outstanding: nil, pageCount: 128))
        XCTAssertThrowsError(try NativeWorkerProtocol.object(Data([255]), limit: 4096))
        XCTAssertThrowsError(
            try NativeWorkerProtocol.validateResponse(
                Data((hello + String(repeating: " ", count: 4096)).utf8), binding: binding, outstanding: nil,
                pageCount: 128))
        let booleanCount = hello.replacingOccurrences(of: "\"pageCount\":128", with: "\"pageCount\":true")
        XCTAssertThrowsError(
            try NativeWorkerProtocol.validateResponse(
                Data(booleanCount.utf8), binding: binding, outstanding: nil, pageCount: 128))
    }
    func testKnownHistoricalIdentityCannotBindActiveNativeWorker() throws {
        let original = try XCTUnwrap(
            String(data: bytes("binding.json", activeIdentity: false), encoding: .utf8))
        let historical = original.replacingOccurrences(
            of: "tractanda.docling-native.v2-idefics3-gelu-f32", with: "tractanda.docling-native.v1"
        )
        .replacingOccurrences(
            of: "opaque-rgb-content-crop-hf4561-pillow123-grid-v2", with: "opaque-rgb2048-17tiles-v1")
        let retained = try JSONDecoder().decode(NativeDocumentBinding.self, from: Data(historical.utf8))
        XCTAssertNoThrow(try retained.identity.validate(), "Known history remains readable")
        XCTAssertThrowsError(try NativeWorkerProtocol.binding(Data(historical.utf8)))
    }

    func testOnlyRealCountersAndPhaseTransitionsAdvanceLiveness() throws {
        var progress = DocumentMeaningfulProgress()
        XCTAssertTrue(try progress.observe(phase: "modelVerify", completed: 0, total: 100))
        XCTAssertFalse(progress.pageStarted)
        XCTAssertFalse(try progress.observe(phase: "modelVerify", completed: 0, total: 200))
        XCTAssertTrue(try progress.observe(phase: "modelVerify", completed: 10, total: 200))
        XCTAssertThrowsError(try progress.observe(phase: "modelVerify", completed: 9, total: 200))
        XCTAssertTrue(try progress.observe(phase: "modelLoad", completed: 0, total: 0))
        XCTAssertFalse(try progress.observe(phase: "modelLoad", completed: 0, total: 0))
        XCTAssertTrue(try progress.observe(phase: "modelReady", completed: 0, total: 0))
        XCTAssertFalse(progress.pageStarted, "Load timeout cannot become an invented page outcome")
        XCTAssertTrue(try progress.observe(phase: "render", completed: 0, total: 0))
        XCTAssertTrue(progress.pageStarted)
        XCTAssertThrowsError(try progress.observe(phase: "prepare", completed: 1, total: 0))
        XCTAssertTrue(try progress.observe(phase: "generate", completed: 0, total: 262144))
        XCTAssertFalse(try progress.observe(phase: "generate", completed: 0, total: 262144))
        XCTAssertTrue(try progress.observe(phase: "generate", completed: 1, total: 262144))
        XCTAssertThrowsError(try progress.observe(phase: "prefill", completed: 1, total: 2))
        progress.beginPage()
        XCTAssertFalse(progress.pageStarted)
        XCTAssertTrue(try progress.observe(phase: "render", completed: 0, total: 0))
        XCTAssertThrowsError(try progress.observe(phase: "modelLoad", completed: 0, total: 0))
    }
    func testAbsolutePhaseBudgetsIgnoreHeartbeatsAndResetOnlyForNewPhasePage() throws {
        let now = ContinuousClock.now
        let budgets = try DocumentWorkerBudgets(inspect: 30, modelLoad: 180, page: 240, noProgress: 60)
        var limit = DocumentWorkerDeadline(budgets: budgets, phase: .inspect, now: now)
        XCTAssertEqual(limit.deadline, now.advanced(by: .seconds(30)))
        limit.begin(.modelLoad, now: now)
        limit.observe(meaningful: false, now: now.advanced(by: .seconds(50)))
        XCTAssertEqual(limit.deadline, now.advanced(by: .seconds(60)))
        limit.observe(meaningful: true, now: now.advanced(by: .seconds(50)))
        XCTAssertEqual(limit.deadline, now.advanced(by: .seconds(110)))
        limit.observe(meaningful: true, now: now.advanced(by: .seconds(170)))
        XCTAssertEqual(
            limit.deadline, now.advanced(by: .seconds(180)),
            "Meaningful progress cannot renew the absolute phase budget")
        limit.begin(.page, now: now.advanced(by: .seconds(180)))
        XCTAssertEqual(limit.deadline, now.advanced(by: .seconds(240)))
        limit.begin(.page, now: now.advanced(by: .seconds(400)))
        XCTAssertEqual(
            limit.deadline, now.advanced(by: .seconds(460)), "There is no total-document360second cap")
        XCTAssertThrowsError(try DocumentWorkerBudgets(page: .infinity))
        XCTAssertThrowsError(try DocumentWorkerBudgets(noProgress: 0))
    }

    func testTimeoutContextUsesDeadlineOriginAndDoesNotRenewLiveness() throws {
        let now = ContinuousClock.now
        let budgets = try DocumentWorkerBudgets(modelLoad: 180, page: 180, noProgress: 60)
        var limit = DocumentWorkerDeadline(budgets: budgets, phase: .modelLoad, now: now)
        let unknown = limit.timeoutFailure(lastPhase: nil, now: now.advanced(by: .seconds(61)))
        XCTAssertEqual(unknown.code, "documentTimeout")
        XCTAssertTrue(unknown.message.contains("phase=unknown; timeout=noProgress; budgetSeconds=60.0"))
        XCTAssertTrue(unknown.message.contains("elapsedSeconds=61.0"))
        limit.observe(meaningful: true, now: now.advanced(by: .seconds(20)))
        limit.observe(meaningful: false, now: now.advanced(by: .seconds(70)))
        let failure = limit.timeoutFailure(lastPhase: "modelLoad", now: now.advanced(by: .seconds(81)))
        XCTAssertTrue(failure.message.contains("phase=modelLoad; timeout=noProgress"))
        XCTAssertTrue(failure.message.contains("elapsedSeconds=61.0"))
        XCTAssertEqual(limit.deadline, now.advanced(by: .seconds(80)))
        _ = limit.timeoutFailure(lastPhase: "modelLoad", now: now.advanced(by: .seconds(100)))
        XCTAssertEqual(limit.deadline, now.advanced(by: .seconds(80)), "Diagnostics cannot renew liveness")
        limit.begin(.page, now: now)
        limit.observe(meaningful: true, now: now.advanced(by: .seconds(170)))
        let page = limit.timeoutFailure(lastPhase: "generate", now: now.advanced(by: .seconds(181)))
        XCTAssertTrue(page.message.contains("phase=generate; timeout=page; budgetSeconds=180.0"))
        XCTAssertTrue(page.message.contains("elapsedSeconds=181.0"))
    }

    func testConfigurablePlatformResourceDefaultsAndSilentCPUDeadline() throws {
        let defaults = try DocumentJobResources().budgets()
        XCTAssertEqual(defaults.modelLoad, 3600)
        XCTAssertEqual(defaults.page, 21600)
        XCTAssertEqual(defaults.noProgress, 1800)
        XCTAssertEqual(defaults.inspect, 1800)
        XCTAssertEqual(defaults.terminationGrace, 15)
        XCTAssertEqual(try DocumentWorkerBudgets().page, defaults.page)
        let now = ContinuousClock.now
        let configured = try DocumentJobResources(
            inspectSeconds: 90, modelLoadSeconds: 7200, pageSeconds: 86400,
            noProgressSeconds: 3600, terminationGraceSeconds: 5
        ).budgets()
        var deadline = DocumentWorkerDeadline(budgets: configured, phase: .page, now: now)
        deadline.observe(meaningful: true, workerPhase: "prefill", now: now)
        XCTAssertEqual(deadline.deadline, now.advanced(by: .seconds(86400)))
        deadline.observe(meaningful: false, workerPhase: "prefill", now: now.advanced(by: .seconds(80000)))
        XCTAssertEqual(
            deadline.deadline, now.advanced(by: .seconds(86400)),
            "Silence cannot renew the absolute page limit")
        let failure = deadline.timeoutFailure(lastPhase: "prefill", now: now.advanced(by: .seconds(86401)))
        XCTAssertTrue(failure.message.contains("timeout=page"))

        deadline.begin(.page, now: now)
        deadline.observe(meaningful: true, workerPhase: "generate", now: now)
        XCTAssertEqual(deadline.deadline, now.advanced(by: .seconds(3600)))
        deadline.observe(meaningful: false, workerPhase: "generate", now: now.advanced(by: .seconds(3500)))
        XCTAssertEqual(
            deadline.deadline, now.advanced(by: .seconds(3600)), "Repeated counters cannot renew liveness")
        XCTAssertNoThrow(try DocumentJobResources(pageSeconds: 7 * 86400).validate())
        XCTAssertThrowsError(try DocumentJobResources(pageSeconds: .infinity).validate())
        XCTAssertThrowsError(try DocumentJobResources(noProgressSeconds: 0).validate())
    }

}
