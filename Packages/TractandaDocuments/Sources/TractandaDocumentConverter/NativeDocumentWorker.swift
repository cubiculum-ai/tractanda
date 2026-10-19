import DoclingRaster
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXNN
import MLXVLM
import TractandaClient
import VMLXTokenizers

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

private final class ProtocolWriter {
    private let file: FileHandle
    let binding: NativeDocumentBinding
    init(binding: NativeDocumentBinding, descriptor: Int32) {
        self.binding = binding
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func frame(_ fields: [String: Any], request: NativeWorkerRequest? = nil, pageCount: Int64) throws {
        var value = try NativeWorkerProtocol.boundObject(binding)
        for (key, field) in fields { value[key] = field }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try NativeWorkerProtocol.validateResponse(
            data, binding: binding, outstanding: request, pageCount: pageCount)
        try file.write(contentsOf: data + Data([10]))
    }
    func progress(
        _ phase: String, completed: Int64 = 0, total: Int64 = 0, request: NativeWorkerRequest,
        pageCount: Int64
    ) throws {
        try frame(
            [
                "type": "progress", "requestID": request.requestID, "pageNumber": request.pageNumber!,
                "phase": phase, "completed": completed, "total": total,
            ], request: request, pageCount: pageCount)
    }
}

/// One trusted Core-bound descriptor and model context; durable state belongs to Core.
enum NativeDocumentWorker {
    static func main(_ args: [String]) async {
        #if os(Linux)
            await Device.withDefaultDevice(.cpu) { await run(args) }
        #else
            await run(args)
        #endif
    }
    private static func run(_ args: [String]) async {
        // Reserve protocol stdout first, before any runtime operations can print.
        let protocolFD = dup(STDOUT_FILENO)
        guard protocolFD >= 0, fcntl(protocolFD, F_SETFD, FD_CLOEXEC) == 0,
            dup2(STDERR_FILENO, STDOUT_FILENO) >= 0
        else { exit(1) }
        var writer: ProtocolWriter?
        var inspectOutput: URL?
        do {
            guard args.count == 5 else { throw NativeWorkerProtocol.invalid() }
            let inspect = args[0] == "inspect-v1"
            let sourcePath = args[inspect ? 1 : 2]
            let mediaType = args[inspect ? 2 : 3]
            let bindingPath = args[inspect ? 3 : 4]
            for path in [sourcePath, bindingPath, args[1], args[4]] {
                guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0")
                else { throw NativeWorkerProtocol.invalid() }
            }
            if inspect { inspectOutput = URL(fileURLWithPath: args[4]) }
            let binding = try NativeWorkerProtocol.binding(try boundedBinding(bindingPath))
            guard binding.source.mediaType == mediaType else { throw NativeWorkerProtocol.invalid() }
            writer = ProtocolWriter(binding: binding, descriptor: protocolFD)
            let session = try DoclingFileRasterSession.open(
                at: URL(fileURLWithPath: sourcePath), mediaType: mediaType, expected: binding.file)
            defer { session.close() }
            let hello: [String: Any] = [
                "type": "hello", "pageCount": session.pageCount,
                "modelLoaded": false, "modelForwardCalls": 0,
            ]
            if let inspectOutput {
                try saveInspection(
                    hello, writer: writer!, pageCount: session.pageCount, output: inspectOutput)
                return
            }
            try writer!.frame(hello, pageCount: session.pageCount)
            let reader = NativeWorkerLineReader(file: .standardInput)
            var previousID: Int64 = 0
            var context: ModelContext?
            while let data = try reader.next(limit: NativeWorkerProtocol.requestBytes) {
                let request = try NativeWorkerProtocol.request(
                    data, binding: binding, previousID: previousID, pageCount: session.pageCount)
                previousID = request.requestID
                if request.method == "close" {
                    try session.validateSource()
                    try writer!.frame(
                        ["type": "closed", "requestID": request.requestID], request: request,
                        pageCount: session.pageCount)
                    return
                }
                try session.validateSource()
                if context == nil {
                    try writer!.progress("modelVerify", request: request, pageCount: session.pageCount)
                    do {
                        let model = URL(fileURLWithPath: args[1], isDirectory: true)
                        try verifyModel(model) { done, total in
                            try writer!.progress(
                                "modelVerify", completed: done, total: total, request: request,
                                pageCount: session.pageCount)
                        }
                        let expected = try expectedWeights(model)
                        try writer!.progress("modelLoad", request: request, pageCount: session.pageCount)
                        var loaded = try await VLMModelFactory.shared.load(
                            from: model, using: #huggingFaceTokenizerLoader())
                        let actual = Dictionary(
                            uniqueKeysWithValues: loaded.model.parameters().flattened().map {
                                ($0.0, $0.1.shape)
                            })
                        try require(actual == expected, "Loaded model weights differ.")
                        let vision = loaded.model.parameters().flattened().first {
                            $0.0 == "vision_model.embeddings.patch_embedding.weight"
                        }!.1
                        try require(vision.dtype == .bfloat16, "Loaded vision weights are not BF16.")
                        loaded.model.train(false)
                        loaded.processor = NativeDocumentInput(
                            tokenizer: loaded.tokenizer, traceDirectory: nil, comparisonDirectory: nil)
                        context = loaded
                        try writer!.progress("modelReady", request: request, pageCount: session.pageCount)
                    } catch {
                        // A model error is systemic; never invent unvisited page outcomes.
                        throw TractandaError(
                            "pinnedModelMismatch", "Pinned native model could not be loaded.")
                    }
                }
                let fields: [String: Any]
                do {
                    try writer!.progress("render", request: request, pageCount: session.pageCount)
                    let raster = try session.render(pageNumber: request.pageNumber!)
                    var active = context!
                    let result = try await convertPage(
                        raster, context: &active, writer: writer!, request: request,
                        pageCount: session.pageCount)
                    context = active
                    try session.validateSource()
                    if let result {
                        fields = [
                            "type": "page", "requestID": request.requestID, "pageNumber": request.pageNumber!,
                            "status": "converted",
                            "page": try JSONSerialization.jsonObject(with: JSON.encode(result)),
                        ]
                    } else {
                        fields = failure(request, status: "truncated", code: "truncatedDocumentOutput")
                    }
                } catch let error as DoclingRasterError {
                    if [.sourceChanged, .sourceReadFailed, .sourceIdentityMismatch].contains(error) {
                        throw error
                    }
                    // A decoder error must not hide a concurrently changed/read-failed source.
                    try session.validateSource()
                    fields =
                        error == .renderingFailed
                        ? failure(request, status: "failed", code: "nativePageFailed")
                        : failure(request, status: "unsupported", code: "unsupportedDocumentInput")
                } catch {
                    // Preparation errors occur before generation; abnormal worker/runtime failure
                    // outside this path exits the session and is supervised by Core.
                    try session.validateSource()
                    fields = failure(request, status: "failed", code: "nativePageFailed")
                }
                try writer!.frame(fields, request: request, pageCount: session.pageCount)
                // Do not reuse a context after an unexpected preparation/runtime exception.
                // Core retains this explicit terminal outcome and may start a fresh worker.
                if fields["status"] as? String == "failed" { return }
            }
        } catch {
            let code: String
            if let error = error as? DoclingRasterError {
                switch error {
                case .sourceChanged: code = "sourceChanged"
                case .sourceReadFailed: code = "sourceReadFailed"
                case .sourceIdentityMismatch: code = "sourceIdentityMismatch"
                default: code = "unsupportedDocumentInput"
                }
            } else if let error = error as? TractandaError {
                code =
                    ["pinnedModelMismatch", "invalidNativeProtocol"].contains(error.code)
                    ? error.code : "nativeWorkerFailed"
            } else {
                code = "nativeWorkerFailed"
            }
            if let writer {
                let fields: [String: Any] = ["type": "error", "failureCode": code]
                if let inspectOutput {
                    try? saveInspection(fields, writer: writer, pageCount: 0, output: inspectOutput)
                } else {
                    try? writer.frame(fields, pageCount: 0)
                }
            } else {
                close(protocolFD)
            }
            // Binding parse failures cannot safely fabricate a fully bound error frame.
            FileHandle.standardError.write(Data(("\(code): native worker failed.\n").utf8))
            exit(1)
        }
    }
    private static func failure(_ request: NativeWorkerRequest, status: String, code: String) -> [String: Any]
    {
        [
            "type": "page", "requestID": request.requestID, "pageNumber": request.pageNumber!,
            "status": status, "failureCode": code,
        ]
    }
    private static func boundedBinding(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeWorkerProtocol.invalid() }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            metadata.st_size > 0, metadata.st_size <= NativeWorkerProtocol.requestBytes
        else { throw NativeWorkerProtocol.invalid() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try file.read(upToCount: NativeWorkerProtocol.requestBytes + 1) ?? Data()
        guard data.count == metadata.st_size else { throw NativeWorkerProtocol.invalid() }
        return data
    }
    private static func saveInspection(
        _ fields: [String: Any], writer: ProtocolWriter, pageCount: Int64, output: URL
    ) throws {
        var value = try NativeWorkerProtocol.boundObject(writer.binding)
        for (key, field) in fields { value[key] = field }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try NativeWorkerProtocol.validateResponse(
            data, binding: writer.binding, outstanding: nil, pageCount: pageCount)
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeWorkerProtocol.invalid() }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data + Data([10]))
        guard fsync(fd) == 0 else { throw NativeWorkerProtocol.invalid() }
        let directory = open(output.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { if directory >= 0 { close(directory) } }
        guard directory >= 0, fsync(directory) == 0 else { throw NativeWorkerProtocol.invalid() }
    }
    private static func convertPage(
        _ raster: DocumentRasterPage, context: inout ModelContext, writer: ProtocolWriter,
        request: NativeWorkerRequest, pageCount: Int64
    ) async throws -> DocumentGeneratedPage? {
        try writer.progress("prepare", request: request, pageCount: pageCount)
        context.processor = NativeDocumentInput(
            tokenizer: context.tokenizer, traceDirectory: nil, comparisonDirectory: nil)
        let rgb = MLXArray(Array(raster.rgb.bytes)).reshaped(raster.rgb.height, raster.rgb.width, 3)
        let input = try await context.processor.prepare(
            input: UserInput(prompt: "Convert this page to docling.", images: [.array(rgb)]))
        try writer.progress("prefill", request: request, pageCount: pageCount)
        let stream = try generate(
            input: input, cache: nil,
            parameters: GenerateParameters(maxTokens: 1024, temperature: 0, randomSeed: 17), context: context)
        var raw = ""
        var tokens = 0
        var stop = "missing_completion"
        var tooLarge = false
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if chunk.utf8.count > DoclingParsedPage.maximumRawBytes - raw.utf8.count { tooLarge = true }
                if !tooLarge { raw += chunk }
                try writer.progress(
                    "generate", completed: Int64(raw.utf8.count), total: 262_144, request: request,
                    pageCount: pageCount)
            case .prefillProgress(let progress):
                try writer.progress(
                    "prefill", completed: Int64(progress.completedUnitCount),
                    total: Int64(progress.totalUnitCount), request: request, pageCount: pageCount)
            case .info(let info):
                tokens = info.generationTokenCount
                stop = String(describing: info.stopReason)
                try writer.progress("drain", request: request, pageCount: pageCount)
            default: break
            }
        }
        // Natural stream termination includes the pinned runtime's GPU/cache/advisor tail.
        guard !tooLarge, stop == "stop", tokens < 1024, raw.contains("</doctag>") else { return nil }
        return DocumentGeneratedPage(
            pageNumber: raster.pageNumber, geometry: raster.geometry,
            rasterSHA256: sha256(raster.rgb.bytes), rawDocTags: raw, generatedTokens: tokens, stopReason: stop
        )
    }
}
