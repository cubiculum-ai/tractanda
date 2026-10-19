import Foundation
import NIOCore
import TractandaCore

enum PeerExchangeCodec {
    static let maximumFrameBytes = 2 * 1024 * 1024
    enum Kind: String, Codable, Sendable {
        case declaration, acknowledgement, ready, request, response, failure
    }
    struct Frame: Codable, Sendable {
        let version: Int
        let requestID: UInt64
        let kind: Kind
        let body: Data
    }
    static func encode(_ frame: Frame, allocator: ByteBufferAllocator) throws -> ByteBuffer {
        let data = try JSON.encode(frame)
        guard !data.isEmpty, data.count <= maximumFrameBytes else {
            throw TractandaError("resourceLimit", "Peer frame size exceeded.")
        }
        var buffer = allocator.buffer(capacity: data.count + 4)
        buffer.writeInteger(UInt32(data.count))
        buffer.writeBytes(data)
        return buffer
    }
    static func decode(_ data: Data) throws -> Frame {
        guard data.count <= maximumFrameBytes else {
            throw TractandaError("resourceLimit", "Peer frame size exceeded.")
        }
        let frame = try JSON.decode(Frame.self, data)
        guard frame.version == 2,
            frame.kind == .declaration || frame.kind == .acknowledgement || frame.kind == .ready
                ? frame.requestID == 0 : frame.requestID > 0, try JSON.encode(frame) == data
        else {
            throw TractandaError("invalidPeerFrame", "Invalid or noncanonical peer frame.")
        }
        return frame
    }
}
