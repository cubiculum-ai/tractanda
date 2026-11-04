import Foundation
import TractandaClient

/// Normal storage reads and writes the current message encoding. The historical MIME/JSON
/// decoder belongs to the external installer bridge.
public enum RecordCodec {
    public static func encode(_ revision: Revision) throws -> Data { try MessageRecordCodec.encode(revision) }
    public static func decode(_ data: Data) throws -> Revision { try MessageRecordCodec.decode(data) }
}
