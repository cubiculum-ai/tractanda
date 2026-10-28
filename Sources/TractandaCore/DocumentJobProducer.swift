import Dispatch
import Foundation

/// Operator phase resources can change without invalidating immutable extraction identity.
public struct DocumentJobResources: Codable, Sendable {
    // Operational limits are configurable for much slower CPU hardware. A silent
    // prefill retains its absolute page limit rather than a counter watchdog.
    public static let defaultInspectSeconds: Double = 1800
    public static let defaultModelLoadSeconds: Double = 3600
    public static let defaultPageSeconds: Double = 21600
    public static let defaultNoProgressSeconds: Double = 1800
    public static let defaultTerminationGraceSeconds: Double = 15
    public let inspectSeconds: Double
    public let modelLoadSeconds: Double
    public let pageSeconds: Double
    public let noProgressSeconds: Double
    public let terminationGraceSeconds: Double
    public init(
        inspectSeconds: Double = DocumentJobResources.defaultInspectSeconds,
        modelLoadSeconds: Double = DocumentJobResources.defaultModelLoadSeconds,
        pageSeconds: Double = DocumentJobResources.defaultPageSeconds,
        noProgressSeconds: Double = DocumentJobResources.defaultNoProgressSeconds,
        terminationGraceSeconds: Double = DocumentJobResources.defaultTerminationGraceSeconds
    ) {
        self.inspectSeconds = inspectSeconds
        self.modelLoadSeconds = modelLoadSeconds
        self.pageSeconds = pageSeconds
        self.noProgressSeconds = noProgressSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
    }
    public func validate() throws { _ = try budgets() }
    func budgets() throws -> DocumentWorkerBudgets {
        try DocumentWorkerBudgets(
            inspect: inspectSeconds, modelLoad: modelLoadSeconds,
            page: pageSeconds, noProgress: noProgressSeconds, terminationGrace: terminationGraceSeconds)
    }
}
struct DocumentJobRuntime: Sendable {
    let configuration: DocumentConverterConfiguration
    let executableSHA256: String
    let configurationSHA256: String
}
struct DocumentJobAdmission: Sendable {
    let jobID: String
    let actorUID: UInt32
    let generation: Int64
    let discard: Bool
}
struct DocumentJobNativeCall: Sendable {
    let method: String
    let callID: String
    let arguments: Data
}
struct DocumentJobDispatch: Sendable {
    let response: NativeMethodOutcome
    let admission: DocumentJobAdmission?
}

/// This serial queue owns every synchronous material traversal and the process/session lifetime.
/// Its async boundary never carries Store, an access context, or a live SQLite writer.
final class DocumentJobProducer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.tractanda.document-producer")
    let work: DocumentJobMaterialWork
    let cancellation: DocumentConversionCancellation
    private let runtime: DocumentJobRuntime?
    private let budgets: DocumentWorkerBudgets
    private let runtimeVerifier: DocumentRuntimeVerifier
    private var original: DocumentVerifiedOriginal?
    private var stage: DocumentPageStageWorker?
    private var session: DocumentNativeSession?
    private var inspectedPageCount: Int64?
    init(
        work: DocumentJobMaterialWork, runtime: DocumentJobRuntime?,
        budgets: DocumentWorkerBudgets, cancellation: DocumentConversionCancellation,
        runtimeVerifier: @escaping DocumentRuntimeVerifier = DocumentNativeSession.verifyRuntime
    ) {
        self.work = work
        self.runtime = runtime
        self.budgets = budgets
        self.cancellation = cancellation
        self.runtimeVerifier = runtimeVerifier
    }
    func perform<T: Sendable>(_ body: @escaping @Sendable (DocumentJobProducer) throws -> T) async throws -> T
    {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try body(self)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    func recover() throws -> DocumentStageSeal {
        try cancellation.check()
        original = try work.verifyOriginal(cancellation: cancellation)
        let worker = work.stage()
        stage = worker
        let seal = try worker.recover()
        try cancellation.check()
        return seal
    }
    func inspect() throws -> Int64 {
        try cancellation.check()
        if work.checkpoint.prepared != nil, let count = work.checkpoint.pageCount { return count }
        try openSession()
        inspectedPageCount = session!.pageCount
        return session!.pageCount
    }
    private func openSession() throws {
        guard let runtime, let original else {
            throw TractandaError("documentConverterUnavailable", "Configure the native document producer.")
        }
        session = nil  // Reap and remove the previous failed-terminal session before a new context.
        session = try work.contents.makeNativeSession(
            intent: work.intent, original: original,
            configuration: runtime.configuration, executableSHA256: runtime.executableSHA256,
            budgets: budgets, cancellation: cancellation,
            expectedPageCount: inspectedPageCount ?? work.checkpoint.pageCount,
            runtimeVerifier: runtimeVerifier)
    }
    func convert(_ number: Int64) throws -> DocumentStoredPage {
        try cancellation.check()
        if session?.ended == true { try openSession() }
        guard let session else { throw NativeWorkerProtocol.invalid() }
        let page = try session.convert(number)
        try cancellation.check()
        return page
    }
    func append(_ page: DocumentStoredPage, pageCount: Int64) throws -> DocumentStageSeal {
        try cancellation.check()
        guard let stage else { throw NativeWorkerProtocol.invalid() }
        return try stage.append(page, pageCount: pageCount)
    }
    func prepare(pageCount: Int64) throws -> DocumentStageSeal {
        try cancellation.check()
        try session?.close()
        session = nil
        try original?.check()
        guard let stage else { throw NativeWorkerProtocol.invalid() }
        return try stage.prepare(pageCount: pageCount)
    }
    func publishContent(_ prepared: PreparedDocumentContent) throws -> DocumentContentReference {
        try cancellation.check()
        try original?.check()
        guard prepared.stage == work.intent.stage, prepared.source == work.intent.source,
            prepared.identity == work.intent.identity
        else { throw NativeWorkerProtocol.invalid() }
        let content = try work.contents.publishPrepared(prepared)
        try original?.check()
        try cancellation.check()
        return content
    }
    func dispose() throws {
        // Authorization tombstone already fenced producers; disposal itself must finish on shutdown.
        try work.stage().discard()
    }
    func close() {
        session = nil
        stage = nil
        original = nil
    }
}
