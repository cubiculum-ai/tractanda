import Foundation

struct DocumentNativeSessionFailure: Error {
    let failure: TractandaError
    let requestedPage: Int64?
    let pageStarted: Bool
    let timeoutMessage: String?
}

/// One retained source and lazily loaded model context. Caller owns one outstanding request.
final class DocumentNativeSession {
    let binding: NativeDocumentBinding
    let pageCount: Int64
    private let original: DocumentVerifiedOriginal
    private let files: DocumentContentFiles
    private let process: DocumentOwnedProcess
    private let budgets: DocumentWorkerBudgets
    private let bindingBytes: Int
    private var requestID: Int64 = 0
    private var progress = DocumentMeaningfulProgress()
    private(set) var ended = false

    init(
        intent: DocumentJobIntent, original: DocumentVerifiedOriginal,
        configuration: DocumentConverterConfiguration,
        expectedExecutableSHA256: String, files: DocumentContentFiles, root: URL,
        budgets: DocumentWorkerBudgets, cancellation: DocumentConversionCancellation,
        expectedPageCount: Int64? = nil
    ) throws {
        try original.check()
        try cancellation.check()
        guard try DocumentProcess.executableSHA256(configuration.executablePath) == expectedExecutableSHA256
        else {
            throw TractandaError(
                "documentConfigurationChanged", "Native executable differs from its configured identity.")
        }
        let sessionID = try UUID.makeVersion1().uuidString.lowercased()
        let binding = NativeDocumentBinding(
            protocolName: NativeWorkerProtocol.name, jobID: intent.jobID,
            sessionID: sessionID, source: intent.source, identity: intent.identity, file: original.file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(binding)
        _ = try NativeWorkerProtocol.binding(data)
        let path = ["document-jobs", intent.jobID, "sessions", sessionID, "binding.json"]
        let bindingPath = path.reduce(root) { $0.appendingPathComponent($1) }.path
        var launched: DocumentOwnedProcess?
        let inspection = DocumentWorkerDeadline(budgets: budgets, phase: .inspect)
        do {
            try files.writeImmutable(data, path: path, maximumBytes: NativeWorkerProtocol.requestBytes)
            let child = try DocumentOwnedProcess(
                executable: configuration.executablePath,
                arguments: [
                    "worker-v1", configuration.modelDirectory, original.path, intent.source.mediaType,
                    bindingPath,
                ],
                cancellation: cancellation, graceSeconds: budgets.terminationGrace)
            launched = child
            let deadline = inspection.deadline
            guard let hello = try child.nextLine(limit: NativeWorkerProtocol.controlBytes, deadline: deadline)
            else {
                throw TractandaError(
                    "nativeWorkerFailed", "Native worker ended before weight-free inspection.")
            }
            try NativeWorkerProtocol.validateResponse(hello, binding: binding, outstanding: nil, pageCount: 0)
            let object = try NativeWorkerProtocol.object(hello, limit: NativeWorkerProtocol.controlBytes)
            if object["type"] as? String == "error" {
                throw TractandaError(object["failureCode"] as! String, "Native worker inspection failed.")
            }
            guard object["type"] as? String == "hello" else { throw NativeWorkerProtocol.invalid() }
            let count = try NativeWorkerProtocol.integer(object["pageCount"] as Any)
            guard expectedPageCount == nil || expectedPageCount == count else {
                throw TractandaError(
                    "documentOriginalChanged", "Inspected page count differs from retained job coverage.")
            }
            try original.check()
            self.binding = binding
            self.pageCount = count
            self.original = original
            self.files = files
            self.process = child
            self.budgets = budgets
            self.bindingBytes = data.count
        } catch {
            let timeout =
                error is DocumentWorkerDeadlineExpired
                ? inspection.timeoutFailure(lastPhase: nil) : nil
            let failure: Error =
                timeout.map {
                    DocumentNativeSessionFailure(
                        failure: $0, requestedPage: nil, pageStarted: false, timeoutMessage: $0.message)
                } ?? error
            launched?.terminateAndWait()
            try? files.removeJobSession(jobID: intent.jobID, sessionID: sessionID, chargedBytes: data.count)
            throw failure
        }
    }
    deinit {
        process.terminateAndWait()
        try? files.removeJobSession(
            jobID: binding.jobID, sessionID: binding.sessionID, chargedBytes: bindingBytes)
    }
    private func nextRequest(method: String, pageNumber: Int64?) throws -> NativeWorkerRequest {
        let next = requestID.addingReportingOverflow(1)
        guard !next.overflow, !ended else { throw NativeWorkerProtocol.invalid() }
        requestID = next.partialValue
        return NativeWorkerRequest(
            protocolName: NativeWorkerProtocol.name, jobID: binding.jobID,
            sessionID: binding.sessionID, requestID: requestID, method: method, pageNumber: pageNumber)
    }
    private func send(_ request: NativeWorkerRequest, deadline: ContinuousClock.Instant) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(request)
        _ = try NativeWorkerProtocol.request(
            bytes, binding: binding, previousID: request.requestID - 1, pageCount: pageCount)
        try process.writeLine(bytes, deadline: deadline)
    }
    func convert(_ number: Int64, observe: (String, Int64, Int64) throws -> Void = { _, _, _ in }) throws
        -> DocumentStoredPage
    {
        guard number > 0, number <= pageCount else { throw NativeWorkerProtocol.invalid() }
        try original.check()
        let request = try nextRequest(method: "convertPage", pageNumber: number)
        progress.beginPage()
        var deadline = DocumentWorkerDeadline(
            budgets: budgets, phase: progress.modelReady ? .page : .modelLoad)
        do {
            try send(request, deadline: deadline.deadline)
            while true {
                guard
                    let data = try process.nextLine(
                        limit: NativeWorkerProtocol.pageBytes, deadline: deadline.deadline)
                else {
                    throw TractandaError(
                        "nativeWorkerFailed", "Native worker ended without a terminal page outcome.")
                }
                try NativeWorkerProtocol.validateResponse(
                    data, binding: binding, outstanding: request, pageCount: pageCount)
                let object = try NativeWorkerProtocol.object(data, limit: NativeWorkerProtocol.pageBytes)
                switch object["type"] as? String {
                case "progress":
                    let phase = object["phase"] as! String
                    let completed = try NativeWorkerProtocol.integer(object["completed"] as Any)
                    let total = try NativeWorkerProtocol.integer(object["total"] as Any)
                    let meaningful = try progress.observe(phase: phase, completed: completed, total: total)
                    if phase == "modelReady", deadline.phase == .modelLoad { deadline.begin(.page) }
                    deadline.observe(meaningful: meaningful)
                    try observe(phase, completed, total)
                case "error":
                    throw TractandaError(
                        object["failureCode"] as! String, "Native worker invalidated its session.")
                case "page":
                    let status = object["status"] as! String
                    let outcome: DocumentStoredPage
                    if status == "converted" {
                        let generated = try JSONDecoder().decode(
                            DocumentGeneratedPage.self,
                            from: JSONSerialization.data(withJSONObject: object["page"] as Any))
                        let parsed = try DoclingDocTagsParser.parse(Data(generated.rawDocTags.utf8))
                        let page = try AttachmentDocumentPage(
                            pageNumber: generated.pageNumber, geometry: generated.geometry,
                            rasterSHA256: generated.rasterSHA256, parsed: parsed,
                            generatedTokens: generated.generatedTokens,
                            stopReason: generated.stopReason)
                        guard
                            page.geometry.sourceUnit
                                == (binding.source.mediaType == "application/pdf" ? "pdfPoint" : "pixel")
                        else {
                            throw TractandaError(
                                "invalidDocumentOutput", "Native page units differ from original media.")
                        }
                        outcome = try DocumentStoredPage(
                            pageNumber: number, sourceSHA256: binding.source.sha256, page: page)
                    } else {
                        outcome = try DocumentStoredPage(
                            pageNumber: number, sourceSHA256: binding.source.sha256,
                            status: status, failureCode: object["failureCode"] as! String)
                    }
                    try original.check()
                    if status == "failed" {
                        deadline.begin(.finish)
                        try process.finish(
                            deadline: deadline.deadline,
                            requireSuccessful: false)
                        ended = true
                    }
                    return outcome
                default: throw NativeWorkerProtocol.invalid()
                }
            }
        } catch {
            let timeout =
                error is DocumentWorkerDeadlineExpired
                ? deadline.timeoutFailure(lastPhase: progress.phase) : nil
            let failure = timeout ?? error as? TractandaError ?? NativeWorkerProtocol.invalid()
            process.terminateAndWait()
            ended = true
            if error is CancellationError { throw error }
            throw DocumentNativeSessionFailure(
                failure: failure,
                requestedPage: number, pageStarted: progress.pageStarted, timeoutMessage: timeout?.message)
        }
    }
    func close() throws {
        if ended { return }
        let request = try nextRequest(method: "close", pageNumber: nil)
        let deadline = DocumentWorkerDeadline(budgets: budgets, phase: .finish)
        do {
            try send(request, deadline: deadline.deadline)
            guard
                let data = try process.nextLine(
                    limit: NativeWorkerProtocol.controlBytes, deadline: deadline.deadline)
            else {
                throw NativeWorkerProtocol.invalid()
            }
            try NativeWorkerProtocol.validateResponse(
                data, binding: binding, outstanding: request, pageCount: pageCount)
            guard
                try NativeWorkerProtocol.object(data, limit: NativeWorkerProtocol.controlBytes)["type"]
                    as? String == "closed"
            else {
                throw NativeWorkerProtocol.invalid()
            }
            try process.finish(deadline: deadline.deadline)
            try original.check()
            ended = true
        } catch {
            let timeout =
                error is DocumentWorkerDeadlineExpired
                ? deadline.timeoutFailure(lastPhase: progress.phase) : nil
            process.terminateAndWait()
            ended = true
            if let timeout {
                throw DocumentNativeSessionFailure(
                    failure: timeout, requestedPage: nil, pageStarted: false, timeoutMessage: timeout.message)
            }
            throw error
        }
    }
}
