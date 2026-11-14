import Foundation
import TractandaCore
import TractandaMemory

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Local preview and report never resolve a connection. The factory is called only for
/// operations that actually contact the selected server.
@discardableResult
func memoryImportCommand(
    _ arguments: [String],
    client: () throws -> (ItemClient, String),
    emit: (Data) -> Void = { print(String(decoding: $0, as: UTF8.self)) }
) throws -> Bool {
    guard let command = arguments.first, command == "import" || command == "export-memory" else {
        return false
    }
    let usage =
        "Use import limits; import preview --adapter directory|okf|codex|claude --source DIR --namespace TOKEN --out PLAN [--limits PRIVATE_JSON]; import inspect PLAN; import apply PLAN --journal NEWDIR; import resume JOURNAL; import report JOURNAL; or export-memory --namespace TOKEN --out NEWDIR. Add --json for a structured summary."
    var words = Array(arguments.dropFirst())
    var json = false
    if let index = words.firstIndex(of: "--json") {
        words.remove(at: index)
        json = true
    }
    guard !words.contains("--json") else { throw TractandaError("usage", usage) }
    func options(_ words: ArraySlice<String>, allowed: Set<String>) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = words.startIndex
        while index < words.endIndex {
            let flag = words[index]
            let next = words.index(after: index)
            guard allowed.contains(flag), values[flag] == nil, next < words.endIndex,
                !words[next].hasPrefix("--"), !words[next].isEmpty
            else { throw TractandaError("usage", usage) }
            values[flag] = words[next]
            index = words.index(after: next)
        }
        return values
    }
    func display(_ report: ImportReport) throws {
        if json {
            emit(try JSON.encode(report))
            return
        }
        let counts = Dictionary(grouping: report.outcomes, by: { $0.disposition.rawValue })
        let order: [ImportDisposition] = [
            .create, .update, .unchanged, .localDivergence, .conflict, .duplicate, .missing,
            .incomplete, .tombstone, .failed,
        ]
        let details = order.compactMap { kind -> String? in
            guard let count = counts[kind.rawValue]?.count, count > 0 else { return nil }
            return "\(kind.rawValue): \(count)"
        }.joined(separator: ", ")
        let diagnostics = report.diagnostics.count + report.outcomes.reduce(0) { $0 + $1.diagnostics.count }
        emit(
            Data(
                "Records: \(report.outcomes.count)\(details.isEmpty ? "" : " (\(details))"); diagnostics: \(diagnostics).\nReplication acknowledgement not established.\n"
                    .utf8))
    }
    if command == "export-memory" {
        let values = try options(words[...], allowed: ["--namespace", "--out"])
        guard values.count == 2, let namespace = values["--namespace"], let path = values["--out"] else {
            throw TractandaError("usage", usage)
        }
        let (selected, endpoint) = try client()
        let report = try ImportBundleExport.export(
            client: selected, namespace: namespace, destination: URL(fileURLWithPath: path),
            endpoint: endpoint,
            limits: ImportLimits())
        try display(report)
        return true
    }
    guard let action = words.first else { throw TractandaError("usage", usage) }
    words.removeFirst()
    switch action {
    case "limits":
        guard words.isEmpty else { throw TractandaError("usage", usage) }
        emit(try JSON.encode(ImportLimits()))
    case "preview":
        let values = try options(
            words[...], allowed: ["--adapter", "--source", "--namespace", "--out", "--limits"])
        guard (4...5).contains(values.count), let adapter = values["--adapter"],
            let source = values["--source"],
            let namespace = values["--namespace"], let path = values["--out"],
            ["directory", "okf", "codex", "claude"].contains(adapter)
        else { throw TractandaError("usage", usage) }
        let limits = try values["--limits"].map { try MemoryPlanFile.readLimits(path: $0) } ?? ImportLimits()
        try limits.validate()
        let sourceURL = URL(fileURLWithPath: source, isDirectory: true)
        let plan: ImportPlan
        if adapter == "okf" {
            plan = try OKFMemoryAdapter.preview(source: sourceURL, namespace: namespace, limits: limits)
        } else {
            plan = try MemoryDirectoryAdapter.preview(
                source: sourceURL, namespace: namespace, origin: adapter, limits: limits)
        }
        try plan.validate()
        try MemoryPlanFile.write(plan, path: path)
        if json {
            emit(
                try JSONSerialization.data(
                    withJSONObject: [
                        "schema": "tractanda.import-preview.v1", "records": plan.records.count,
                        "diagnostics": plan.records.reduce(0) { $0 + $1.diagnostics.count },
                        "planSHA256": plan.sha256,
                    ], options: [.sortedKeys]))
        } else {
            let diagnostics = plan.records.reduce(0) { $0 + $1.diagnostics.count }
            emit(
                Data(
                    "Plan saved: \(plan.records.count) records, \(diagnostics) diagnostics. No server was contacted.\n"
                        .utf8))
        }
    case "inspect":
        guard words.count == 1, !words[0].hasPrefix("--") else { throw TractandaError("usage", usage) }
        let plan = try MemoryPlanFile.read(path: words[0])
        let (selected, endpoint) = try client()
        try display(ImportEngine(client: selected, endpoint: endpoint).preview(plan))
    case "apply":
        guard let path = words.first, !path.hasPrefix("--") else { throw TractandaError("usage", usage) }
        let values = try options(words.dropFirst(), allowed: ["--journal"])
        guard values.count == 1, let journalPath = values["--journal"] else {
            throw TractandaError("usage", usage)
        }
        let plan = try MemoryPlanFile.read(path: path)
        let (selected, endpoint) = try client()
        let journal = try ImportJournal(
            directory: URL(fileURLWithPath: journalPath), create: true, limits: plan.limits)
        try display(ImportEngine(client: selected, endpoint: endpoint).apply(plan, journal: journal))
    case "resume", "report":
        guard words.count == 1, !words[0].hasPrefix("--") else { throw TractandaError("usage", usage) }
        let journal = try ImportJournal(directory: URL(fileURLWithPath: words[0]))
        if action == "report" {
            try display(journal.load().report)
        } else {
            let (selected, endpoint) = try client()
            try display(ImportEngine(client: selected, endpoint: endpoint).resume(journal: journal))
        }
    default: throw TractandaError("usage", usage)
    }
    return true
}

private enum MemoryPlanFile {
    static func write(_ plan: ImportPlan, path: String) throws {
        let data = try JSON.encode(plan)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TractandaError("importPlan", "Cannot create new private plan file.") }
        defer { _ = close(fd) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                memoryFileWrite(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TractandaError("importPlan", "Cannot write plan file.") }
            offset += count
        }
        guard fsync(fd) == 0 else { throw TractandaError("importPlan", "Cannot synchronize plan file.") }
    }
    static func read(path: String) throws -> ImportPlan {
        let plan = try JSON.decode(ImportPlan.self, readBytes(path: path, maximum: 64 * 1024 * 1024))
        try plan.validate()
        return plan
    }
    static func readLimits(path: String) throws -> ImportLimits {
        let limits = try JSON.decode(ImportLimits.self, readBytes(path: path, maximum: 16 * 1024))
        try limits.validate()
        return limits
    }
    private static func readBytes(path: String, maximum: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TractandaError("importPlan", "Cannot open private import input file.") }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
            info.st_size > 0, info.st_size <= maximum
        else { throw TractandaError("importPlan", "Import input file must be private, owned and bounded.") }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        let total = data.count
        while offset < total {
            let remaining = total - offset
            let count = data.withUnsafeMutableBytes {
                memoryFileRead(fd, $0.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TractandaError("importPlan", "Plan file changed while reading.") }
            offset += count
        }
        return data
    }
}

private func memoryFileWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.write(fd, bytes, count)
    #else
        Glibc.write(fd, bytes, count)
    #endif
}

private func memoryFileRead(_ fd: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.read(fd, bytes, count)
    #else
        Glibc.read(fd, bytes, count)
    #endif
}
