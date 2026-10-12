import CryptoKit
import Darwin
import DoclingRaster
import Foundation
import TractandaClient

private func assertProtocol(_ condition: @autoclosure () -> Bool) throws {
    guard condition() else { throw NativeWorkerProtocol.invalid() }
}
private func rejectProtocol(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw NativeWorkerProtocol.invalid()
}

func checkNativeProtocol(_ directory: URL, scratch: URL) throws {
    try checkOpenPipeLineReader()
    let binding = try NativeWorkerProtocol.binding(
        Data(contentsOf: directory.appendingPathComponent("binding.json")))
    var largeBinding = try NativeWorkerProtocol.boundObject(binding)
    var largeSource = largeBinding["source"] as! [String: Any]
    var largeFile = largeBinding["file"] as! [String: Any]
    largeSource["byteCount"] = Int64(9_437_184)
    largeFile["byteCount"] = Int64(9_437_184)
    largeBinding["source"] = largeSource
    largeBinding["file"] = largeFile
    _ = try NativeWorkerProtocol.binding(JSONSerialization.data(withJSONObject: largeBinding))
    let convertData = try Data(contentsOf: directory.appendingPathComponent("request-convert.json"))
    let convert = try NativeWorkerProtocol.request(
        convertData, binding: binding, previousID: 0, pageCount: 128)
    let close = try NativeWorkerProtocol.request(
        Data(contentsOf: directory.appendingPathComponent("request-close.json")), binding: binding,
        previousID: 1, pageCount: 128)
    let manifest =
        try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("FIXTURES.json"))) as! [String: Any]
    for name in manifest["positive"] as! [String] where name.hasPrefix("response-") {
        let outstanding =
            name == "response-hello.json" || name == "response-error.json"
            ? nil
            : name == "response-closed.json" ? close : convert
        try NativeWorkerProtocol.validateResponse(
            Data(contentsOf: directory.appendingPathComponent(name)), binding: binding,
            outstanding: outstanding, pageCount: 128)
    }
    for entry in manifest["negative"] as! [[String: Any]] {
        let name = entry["file"] as! String
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        try rejectProtocol {
            if name.contains("binding") {
                _ = try NativeWorkerProtocol.binding(data)
            } else if name.contains("request") || name.contains("close") {
                _ = try NativeWorkerProtocol.request(data, binding: binding, previousID: 0, pageCount: 128)
            } else {
                try NativeWorkerProtocol.validateResponse(
                    data, binding: binding, outstanding: convert, pageCount: 128)
            }
        }
    }
    let text = String(decoding: convertData, as: UTF8.self)
    let maximum = text.replacingOccurrences(of: "\"requestID\":1", with: "\"requestID\":9223372036854775807")
    let maximumRequest = try NativeWorkerProtocol.request(
        Data(maximum.utf8), binding: binding, previousID: 0, pageCount: 128)
    try assertProtocol(maximumRequest.requestID == .max)
    for altered in [
        text.replacingOccurrences(of: "\"requestID\":1", with: "\"requestID\":true"),
        text.replacingOccurrences(of: "\"requestID\":1", with: "\"requestID\":1.5"),
        text.replacingOccurrences(of: "\"requestID\":1", with: "\"requestID\":1,\"\\u0072equestID\":2"),
        text.replacingOccurrences(of: "\"requestID\":1", with: "\"requestID\":1,\"requestID\":2"),
        text + "{}",
    ] {
        try rejectProtocol {
            _ = try NativeWorkerProtocol.request(
                Data(altered.utf8), binding: binding, previousID: 0, pageCount: 128)
        }
    }
    try rejectProtocol {
        _ = try NativeWorkerProtocol.request(convertData, binding: binding, previousID: 1, pageCount: 128)
    }
    try rejectProtocol { _ = try NativeWorkerProtocol.object(Data([0xFF]), limit: 10) }
    try rejectProtocol {
        _ = try NativeWorkerProtocol.object(Data(repeating: 32, count: 65_537), limit: 65_536)
    }
    for bytes in [convertData.dropLast(), Data(repeating: 32, count: 65_537)] {
        let path = scratch.appendingPathComponent("protocol-line-" + UUID().uuidString)
        try Data(bytes).write(to: path, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        try rejectProtocol { _ = try NativeWorkerLineReader(file: file).next(limit: 65_536) }
    }
}

private func checkOpenPipeLineReader() throws {
    let pipe = Pipe()
    defer {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
    let reader = NativeWorkerLineReader(file: pipe.fileHandleForReading)
    try pipe.fileHandleForWriting.write(contentsOf: Data("first\n".utf8))
    // The writer remains open: waiting for 8192 bytes or EOF would deadlock here.
    let first = try reader.next(limit: 65_536)
    try assertProtocol(first == Data("first".utf8))
    try pipe.fileHandleForWriting.write(contentsOf: Data("second\nthird\n".utf8))
    let second = try reader.next(limit: 65_536)
    let third = try reader.next(limit: 65_536)
    try assertProtocol(second == Data("second".utf8))
    try assertProtocol(third == Data("third".utf8))
    try pipe.fileHandleForWriting.close()
    let end = try reader.next(limit: 65_536)
    try assertProtocol(end == nil)
}

func checkDescriptorSource(_ directory: URL, scratch: URL, largePDF: URL?) throws {
    let original = try Data(contentsOf: directory.appendingPathComponent("portrait-landscape.pdf"))
    let path = scratch.appendingPathComponent("descriptor-source.pdf")
    try original.write(to: path, options: .withoutOverwriting)
    guard chmod(path.path, 0o400) == 0 else { throw NativeWorkerProtocol.invalid() }
    let unbound = try DoclingFileRasterSession.open(at: path, mediaType: "application/pdf", expected: nil)
    let token = unbound.fileIdentity
    unbound.close()
    let pinned = try DoclingFileRasterSession.open(at: path, mediaType: "application/pdf", expected: token)
    defer { pinned.close() }
    let moved = scratch.appendingPathComponent("descriptor-source-retained.pdf")
    try FileManager.default.moveItem(at: path, to: moved)
    try Data("replacement is deliberately not a PDF".utf8).write(to: path, options: .withoutOverwriting)
    guard chmod(path.path, 0o400) == 0 else { throw NativeWorkerProtocol.invalid() }
    let raster = try pinned.render(pageNumber: 1)
    let golden = try DoclingRasterizer.rasterize(original, mediaType: "application/pdf")[0]
    try assertProtocol(raster == golden)
    try rejectProtocol {
        _ = try DoclingFileRasterSession.open(at: path, mediaType: "application/pdf", expected: token)
    }
    let alias = scratch.appendingPathComponent("descriptor-source-symlink.pdf")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: moved)
    try rejectProtocol {
        _ = try DoclingFileRasterSession.open(at: alias, mediaType: "application/pdf", expected: token)
    }
    guard chmod(moved.path, 0o600) == 0 else { throw NativeWorkerProtocol.invalid() }
    try rejectProtocol { _ = try pinned.render(pageNumber: 2) }
    pinned.close()
    for media in ["image/png", "image/jpeg"] {
        if media == "image/jpeg" { continue }  // Frozen JPEG is intentionally orientation-negative.
        let image = directory.appendingPathComponent("paragraph-alpha.png")
        let session = try DoclingFileRasterSession.open(at: image, mediaType: media, expected: nil)
        defer { session.close() }
        let actual = try session.render(pageNumber: 1)
        let expected = try DoclingRasterizer.rasterize(Data(contentsOf: image), mediaType: media)[0]
        try assertProtocol(actual == expected)
    }
    if let largePDF {
        let session = try DoclingFileRasterSession.open(
            at: largePDF, mediaType: "application/pdf", expected: nil)
        defer { session.close() }
        try assertProtocol(session.pageCount == 128 && session.fileIdentity.byteCount > 8 * 1024 * 1024)
        var hashes: [String] = []
        for number: Int64 in [1, 64, 128] {
            let page = try session.render(pageNumber: number)
            try assertProtocol(Int64(page.pageNumber) == number)
            hashes.append(SHA256.hash(data: page.rgb.bytes).map { String(format: "%02x", $0) }.joined())
        }
        try assertProtocol(Set(hashes).count == 3)
        let receipt: [String: Any] = [
            "sourceBytes": session.fileIdentity.byteCount,
            "pageCount": session.pageCount, "renderedPages": [1, 64, 128],
            "rasterHashes": hashes, "modelLoaded": false, "modelForwardCalls": 0,
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(
                to: scratch.appendingPathComponent("large-selected-raster.json"), options: .withoutOverwriting
            )
    }
}
