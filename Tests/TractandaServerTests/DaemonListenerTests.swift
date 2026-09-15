import CTractandaPlatform
import Dispatch
import Foundation
import NIOPosix
import XCTest

@testable import TractandaServer

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DaemonListenerTests: XCTestCase {
    func testTwoListenersServeFragmentedNativeAndHTTPRequests() async throws {
        try await withGroup { group in
            let path = uniqueSocketPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let native = try await DaemonListeners.unix(
                group: group, socketPath: path, permissions: 0o600, managed: false
            ) { body, uid in
                let result: [String: Any] = ["body": String(decoding: body, as: UTF8.self), "uid": uid]
                return try JSONSerialization.data(withJSONObject: result)
            }
            let received = HTTPRecord()
            let http = try await DaemonListeners.http(group: group, port: 0) { request in
                await received.store(request)
                return .init(status: 201, headers: ["x-test": "yes"], body: Data("http-ok".utf8))
            }
            defer {
                try? await native.close()
                try? await http.close()
            }

            let nativeReply = try await blocking {
                try nativeRoundTrip(path, body: Data("native-fragment".utf8), fragmented: true)
            }
            let nativeObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: nativeReply) as? [String: Any])
            XCTAssertEqual(nativeObject["body"] as? String, "native-fragment")
            XCTAssertEqual(nativeObject["uid"] as? UInt32, tractanda_uid())

            let port = try XCTUnwrap(http.port)
            let request = Data(
                "POST /echo HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 10\r\n\r\nfragmented".utf8)
            let reply = try await blocking {
                try httpRoundTrip(port, request: request, fragments: [13, 37, request.count])
            }
            XCTAssertTrue(reply.head.contains("201"))
            XCTAssertEqual(reply.body, Data("http-ok".utf8))
            let captured = try await received.value()
            XCTAssertEqual(captured.method, "POST")
            XCTAssertEqual(captured.body, Data("fragmented".utf8))
            XCTAssertEqual(captured.localPort, port)
        }
    }

    func testSlowNativeClientDoesNotBlockFastRequestAndDisconnectStillFinishes() async throws {
        try await withGroup { group in
            let path = uniqueSocketPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let finished = Counter()
            let listener = try await DaemonListeners.unix(
                group: group, socketPath: path, permissions: 0o600, managed: false
            ) { body, _ in
                if body == Data("finish".utf8) {
                    try await Task.sleep(for: .milliseconds(80))
                    await finished.increment()
                }
                return body
            }
            defer { try? await listener.close() }

            let slow = try await blocking { try nativeConnect(path) }
            defer { tractanda_close(slow) }
            try await blocking { try writeAll(slow, Data([0, 0])) }
            let fast = try await blocking {
                try nativeRoundTrip(path, body: Data("fast".utf8), fragmented: false)
            }
            XCTAssertEqual(fast, Data("fast".utf8))

            try await blocking {
                let fd = try nativeConnect(path)
                defer { tractanda_close(fd) }
                try writeAll(fd, frame(Data("finish".utf8)))
                Thread.sleep(forTimeInterval: 0.03)
                return ()
            }
            try await Task.sleep(for: .milliseconds(180))
            let finishedCount = await finished.value()
            XCTAssertEqual(finishedCount, 1)
        }
    }

    func testBoundsFailuresAndPipeliningDoNotDispatchTwice() async throws {
        try await withGroup { group in
            let path = uniqueSocketPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let native = try await DaemonListeners.unix(
                group: group, socketPath: path, permissions: 0o600, managed: false
            ) { body, _ in
                if body == Data("throw".utf8) { throw ListenerTestError.failed }
                if body == Data("large".utf8) { return Data(repeating: 7, count: 8 * 1024 * 1024 + 1) }
                return body
            }
            let calls = Counter()
            let http = try await DaemonListeners.http(group: group, port: 0) { request in
                await calls.increment()
                if request.uri == "/large" {
                    return .init(body: Data(repeating: 1, count: 8 * 1024 * 1024 + 1))
                }
                return .init(body: Data("ok".utf8))
            }
            defer {
                try? await native.close()
                try? await http.close()
            }

            let failed = try await blocking {
                try nativeRoundTrip(path, body: Data("throw".utf8), fragmented: false)
            }
            XCTAssertTrue(String(decoding: failed, as: UTF8.self).contains("listenerFailure"))
            let oversizedReply = try await blocking {
                try nativeRoundTrip(path, body: Data("large".utf8), fragmented: false)
            }
            XCTAssertTrue(String(decoding: oversizedReply, as: UTF8.self).contains("listenerFailure"))
            let oversizedClosed = try await blocking { try writeOversizedNativeFrame(path) }
            XCTAssertTrue(oversizedClosed)

            let port = try XCTUnwrap(http.port)
            let pipelined = Data(
                "GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
            // A second pipelined request is intentionally not admitted; either the first response
            // wins the race or the close is observed by this deliberately non-compliant client.
            _ = try? await blocking {
                try httpRoundTrip(port, request: pipelined, fragments: [pipelined.count])
            }
            try await Task.sleep(for: .milliseconds(80))
            let callCount = await calls.value()
            XCTAssertEqual(callCount, 1)
            let tooLarge = Data(
                "POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: \(8 * 1024 * 1024 + 1)\r\n\r\n".utf8)
            let tooLargeReply = try await blocking {
                try httpRoundTrip(port, request: tooLarge, fragments: [tooLarge.count])
            }
            XCTAssertTrue(tooLargeReply.head.contains("413"))
            let login = Data("POST /auth/login HTTP/1.1\r\nHost: x\r\nContent-Length: 16385\r\n\r\n".utf8)
            let loginReply = try await blocking {
                try httpRoundTrip(port, request: login, fragments: [login.count])
            }
            XCTAssertTrue(loginReply.head.contains("413"))
            let bigReply = Data("GET /large HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
            let bigResponse = try await blocking {
                try httpRoundTrip(port, request: bigReply, fragments: [bigReply.count])
            }
            XCTAssertTrue(bigResponse.head.contains("500"))
            let headerOverflow = Data(
                "GET /x HTTP/1.1\r\nHost: x\r\nX-Long: \(String(repeating: "a", count: 16 * 1024))\r\n\r\n"
                    .utf8)
            let headerReply = try await blocking {
                try httpRoundTrip(port, request: headerOverflow, fragments: [headerOverflow.count])
            }
            XCTAssertTrue(headerReply.head.contains("431"))
        }
    }

    func testCloseFreesEndpointsAndPreservesExistingOrReplacedPaths() async throws {
        try await withGroup { group in
            let path = uniqueSocketPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
            await assertThrowsErrorAsync {
                _ = try await DaemonListeners.unix(
                    group: group, socketPath: path, permissions: 0o600, managed: true
                ) { _, _ in Data() }
            }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("keep".utf8))
            try FileManager.default.removeItem(atPath: path)

            let livePath = uniqueSocketPath()
            defer { try? FileManager.default.removeItem(atPath: livePath) }
            let live = try await DaemonListeners.unix(
                group: group, socketPath: livePath, permissions: 0o600, managed: false
            ) { body, _ in body }
            await assertThrowsErrorAsync {
                _ = try await DaemonListeners.unix(
                    group: group, socketPath: livePath, permissions: 0o600, managed: true
                ) { _, _ in Data() }
            }
            let liveReply = try await blocking {
                try nativeRoundTrip(livePath, body: Data("live".utf8), fragmented: false)
            }
            XCTAssertEqual(liveReply, Data("live".utf8))
            try await live.close()

            let listener = try await DaemonListeners.unix(
                group: group, socketPath: path, permissions: 0o600, managed: false
            ) { body, _ in body }
            let child = try await blocking { try nativeConnect(path) }
            try await blocking { try writeAll(child, Data([0, 0])) }
            try FileManager.default.removeItem(atPath: path)
            try Data("replacement".utf8).write(to: URL(fileURLWithPath: path))
            try await listener.close()
            tractanda_close(child)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("replacement".utf8))
            try FileManager.default.removeItem(atPath: path)

            let reopened = try await DaemonListeners.unix(
                group: group, socketPath: path, permissions: 0o600, managed: false
            ) { body, _ in body }
            try await reopened.close()
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            try await reopened.close()

            let http = try await DaemonListeners.http(group: group, port: 0) { _ in .init() }
            let port = try XCTUnwrap(http.port)
            try await http.close()
            let rebound = try await DaemonListeners.http(group: group, port: port) { _ in .init() }
            try await rebound.close()
        }
    }

    func testActiveConnectionLimitRejectsSixtyFifthIncompleteClient() async throws {
        try await withGroup { group in
            let path = uniqueSocketPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let listener = try await DaemonListeners.unix(
                group: group, socketPath: path, permissions: 0o600, managed: false
            ) { body, _ in body }
            let clients = try await blocking { try openPartialNativeConnections(path, count: 65) }
            defer {
                for fd in clients { tractanda_close(fd) }
            }
            try await Task.sleep(for: .milliseconds(80))
            let sixtyFifthClosed = try await blocking { try socketWasClosed(clients[64]) }
            XCTAssertTrue(sixtyFifthClosed)
            try await listener.close()
        }
    }
}

private enum ListenerTestError: Error { case failed }

private actor Counter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private actor HTTPRecord {
    private var request: DaemonHTTPRequest?
    func store(_ request: DaemonHTTPRequest) { self.request = request }
    func value() throws -> DaemonHTTPRequest { try XCTUnwrap(request) }
}

private struct HTTPReply: Sendable {
    let head: String
    let body: Data
}

private func withGroup<T: Sendable>(_ body: (MultiThreadedEventLoopGroup) async throws -> T) async throws -> T
{
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    do {
        let value = try await body(group)
        try await group.shutdownGracefully()
        return value
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

private func uniqueSocketPath() -> String { "/tmp/td-\(UUID().uuidString.prefix(12)).sock" }

private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
        }
    }
}

private func nativeConnect(_ path: String) throws -> Int32 {
    let fd = tractanda_connect(path)
    guard fd >= 0 else { throw POSIXError(.ECONNREFUSED) }
    return fd
}

private func frame(_ body: Data) -> Data {
    var length = UInt32(body.count).bigEndian
    var data = Data(bytes: &length, count: 4)
    data.append(body)
    return data
}

private func nativeRoundTrip(_ path: String, body: Data, fragmented: Bool) throws -> Data {
    let fd = try nativeConnect(path)
    defer { tractanda_close(fd) }
    let request = frame(body)
    if fragmented {
        try writeAll(fd, request.prefix(2))
        try writeAll(fd, request.dropFirst(2).prefix(3))
        try writeAll(fd, request.dropFirst(5))
    } else {
        try writeAll(fd, request)
    }
    let length = try readFrameLength(fd)
    return try readExact(fd, count: length)
}

private func openPartialNativeConnections(_ path: String, count: Int) throws -> [Int32] {
    try (0..<count).map { _ in
        let fd = try nativeConnect(path)
        try writeAll(fd, Data([0]))
        return fd
    }
}

private func socketWasClosed(_ fd: Int32) throws -> Bool {
    var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&event, 1, 1_000) > 0 else { return false }
    var byte: UInt8 = 0
    return posixRead(fd, &byte, 1) <= 0
}

private func writeOversizedNativeFrame(_ path: String) throws -> Bool {
    let fd = try nativeConnect(path)
    defer { tractanda_close(fd) }
    var length = UInt32(8 * 1024 * 1024 + 1).bigEndian
    try writeAll(fd, Data(bytes: &length, count: 4))
    var byte: UInt8 = 0
    return posixRead(fd, &byte, 1) <= 0
}

private func readFrameLength(_ fd: Int32) throws -> Int {
    let bytes = try readExact(fd, count: 4)
    return bytes.reduce(0) { ($0 << 8) | Int($1) }
}

private func httpRoundTrip(_ port: Int, request: Data, fragments: [Int]) throws -> HTTPReply {
    let fd = try tcpConnect(port)
    defer { posixClose(fd) }
    var position = 0
    for end in fragments {
        try writeAll(fd, request[position..<min(end, request.count)])
        position = min(end, request.count)
    }
    var data = Data()
    while data.range(of: Data("\r\n\r\n".utf8)) == nil { data.append(try readExact(fd, count: 1)) }
    let split = data.range(of: Data("\r\n\r\n".utf8))!
    let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
    let lengthLine = head.split(whereSeparator: \.isNewline).first {
        $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("content-length:")
    }
    let length =
        Int(
            lengthLine?.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "0") ?? 0
    return HTTPReply(head: head, body: try readExact(fd, count: length))
}

private func tcpConnect(_ port: Int) throws -> Int32 {
    let fd = posixTCPSocket()
    guard fd >= 0 else { throw POSIXError(.ECONNREFUSED) }
    var address = sockaddr_in()
    #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            posixConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        posixClose(fd)
        throw POSIXError(.ECONNREFUSED)
    }
    return fd
}

private func writeAll<S: DataProtocol>(_ fd: Int32, _ data: S) throws {
    var sent = 0
    let bytes = Data(data)
    try bytes.withUnsafeBytes { raw in
        while sent < raw.count {
            let count = posixWrite(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            guard count > 0 else { throw POSIXError(.EPIPE) }
            sent += count
        }
    }
}

private func readExact(_ fd: Int32, count: Int) throws -> Data {
    var result = Data(count: count)
    var offset = 0
    try result.withUnsafeMutableBytes { raw in
        while offset < count {
            let got = posixRead(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            guard got > 0 else { throw POSIXError(.ECONNRESET) }
            offset += got
        }
    }
    return result
}

private func posixClose(_ fd: Int32) {
    #if canImport(Darwin)
        _ = Darwin.close(fd)
    #else
        _ = Glibc.close(fd)
    #endif
}

private func posixRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
    #else
        Glibc.read(fd, buffer, count)
    #endif
}

private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
    #else
        Glibc.write(fd, buffer, count)
    #endif
}

private func posixTCPSocket() -> Int32 {
    #if canImport(Darwin)
        Darwin.socket(AF_INET, SOCK_STREAM, 0)
    #else
        Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func posixConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
        Darwin.connect(fd, address, length)
    #else
        Glibc.connect(fd, address, length)
    #endif
}

private func assertThrowsErrorAsync(
    _ expression: @escaping @Sendable () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
