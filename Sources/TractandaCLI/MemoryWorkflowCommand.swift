import Foundation
import TractandaCore
import TractandaMemory

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The caller chooses a connection lazily; report is local and does not start a service.
@discardableResult
func memoryWorkflowCommand(
    _ arguments: [String], client: () throws -> (ItemClient, String),
    emit: (Data) -> Void = { print(String(decoding: $0, as: UTF8.self)) }
) throws -> Bool {
    guard arguments.first == "memory" else { return false }
    let usage =
        "Use memory recall --binding FILE [--limit 0..62] [--json]; memory remember --binding FILE --fields FILE --journal NEW_DIR [--json]; memory checkpoint --binding FILE --expected-revision UUID --fields FILE --journal NEW_DIR [--json]; memory resume JOURNAL [--json]; or memory report JOURNAL [--json]."
    var words = Array(arguments.dropFirst())
    guard let operation = words.first else { throw TractandaError("usage", usage) }
    words.removeFirst()
    var json = false
    if let index = words.firstIndex(of: "--json") {
        words.remove(at: index)
        json = true
    }
    guard !words.contains("--json") else { throw TractandaError("usage", usage) }
    func values(_ allowed: Set<String>) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < words.count {
            let key = words[index]
            guard allowed.contains(key), result[key] == nil, index + 1 < words.count,
                !words[index + 1].isEmpty, !words[index + 1].hasPrefix("--")
            else { throw TractandaError("usage", usage) }
            result[key] = words[index + 1]
            index += 2
        }
        return result
    }
    func output(_ receipt: MutationReceipt) throws {
        if json {
            emit(try JSON.encode(receipt))
        } else {
            emit(Data("Saved item \(receipt.itemID), revision \(receipt.revisionID).\n".utf8))
        }
    }
    if operation == "report" || operation == "resume" {
        guard words.count == 1, !words[0].hasPrefix("--") else { throw TractandaError("usage", usage) }
        let journal = try MemoryIntentJournal(directory: URL(fileURLWithPath: words[0]))
        if operation == "report" {
            if let receipt = try journal.receipt() {
                try output(receipt)
            } else if json {
                emit(Data("{\"status\":\"pending\"}".utf8))
            } else {
                emit(Data("Pending exact intent; resume with the same destination.\n".utf8))
            }
        } else {
            let (selected, endpoint) = try client()
            try output(MemoryWorkflow(client: selected, endpoint: endpoint).resume(journal: journal))
        }
        return true
    }
    let opts = try values(["--binding", "--limit", "--fields", "--journal", "--expected-revision"])
    guard let bindingPath = opts["--binding"] else { throw TractandaError("usage", usage) }
    let binding = try JSON.decode(
        MemoryWorkflowBinding.self, memoryInput(path: bindingPath, maximum: 32 * 1024))
    try binding.validate()
    switch operation {
    case "recall":
        guard Set(opts.keys).isSubset(of: ["--binding", "--limit"]),
            opts["--limit"] == nil || Int(opts["--limit"]!) != nil
        else { throw TractandaError("usage", usage) }
        let limit = opts["--limit"].flatMap(Int.init) ?? 32
        guard (0...62).contains(limit) else { throw TractandaError("usage", usage) }
        let (selected, endpoint) = try client()
        // Recall is explicitly content-bearing; JSON escaping prevents terminal control injection.
        emit(
            try JSON.encode(
                MemoryWorkflow(client: selected, endpoint: endpoint).recall(binding, limit: limit)))
    case "remember", "checkpoint":
        let keys: Set<String> =
            operation == "remember"
            ? ["--binding", "--fields", "--journal"]
            : ["--binding", "--fields", "--journal", "--expected-revision"]
        guard Set(opts.keys) == keys, let fieldsPath = opts["--fields"], let journalPath = opts["--journal"]
        else {
            throw TractandaError("usage", usage)
        }
        let fields = try JSON.decode(
            [String: ItemValue].self, memoryInput(path: fieldsPath, maximum: 512 * 1024))
        let (selected, endpoint) = try client()
        let journal = try MemoryIntentJournal(directory: URL(fileURLWithPath: journalPath), create: true)
        let workflow = MemoryWorkflow(client: selected, endpoint: endpoint)
        if operation == "remember" {
            try output(workflow.remember(binding, fields: fields, journal: journal))
        } else {
            try output(
                workflow.checkpoint(
                    binding, expectedRevisionID: opts["--expected-revision"]!, fields: fields,
                    journal: journal))
        }
    default: throw TractandaError("usage", usage)
    }
    return true
}

private func memoryInput(path: String, maximum: Int) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw TractandaError("memoryInput", "Cannot open selected input file.") }
    defer { _ = close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
        info.st_size > 0, info.st_size <= maximum
    else {
        throw TractandaError("memoryInput", "Input must be a private, owned and bounded regular file.")
    }
    var data = Data(count: Int(info.st_size))
    let size = data.count
    var offset = 0
    while offset < size {
        let count = data.withUnsafeMutableBytes {
            memoryInputRead(fd, $0.baseAddress!.advanced(by: offset), size - offset)
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw TractandaError("memoryInput", "Selected input changed while reading.") }
        offset += count
    }
    return data
}
private func memoryInputRead(_ fd: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.read(fd, bytes, count)
    #else
        Glibc.read(fd, bytes, count)
    #endif
}
