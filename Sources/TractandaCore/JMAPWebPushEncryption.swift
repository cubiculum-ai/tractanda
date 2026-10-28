import Crypto
import Foundation

/// RFC8291 single-record aes128gcm encoding using fresh P-256 and salt per message.
/// No private key, URL or auth secret is exposed through a service result.
package enum JMAPWebPushEncryption {
    package static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
            value.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    || $0 == 95
            })
        else { return nil }
        let padded =
            value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), base64URL(bytes) == value else { return nil }
        return bytes
    }
    package static func base64URL(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    package static func random(_ count: Int) -> Data {
        // SwiftCrypto's SymmetricKey initializer uses the platform CSPRNG.
        precondition(count == 16 || count == 32)
        return SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
    package static func validate(publicKey: Data, auth: Data) throws {
        guard publicKey.count == 65, publicKey.first == 4, auth.count == 16 else { throw invalid() }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
    }
    package static func encrypt(
        _ plaintext: Data, publicKey: Data, auth: Data,
        sender: P256.KeyAgreement.PrivateKey = .init(), salt: Data = random(16)
    ) throws -> Data {
        try validate(publicKey: publicKey, auth: auth)
        guard plaintext.count <= 3993, salt.count == 16 else { throw invalid() }
        let receiver = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        let senderPublic = sender.publicKey.x963Representation
        let shared = try sender.sharedSecretFromKeyAgreement(with: receiver)
        let info = Data("WebPush: info\0".utf8) + publicKey + senderPublic
        let ikm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: auth, sharedInfo: info, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8),
            outputByteCount: 16)
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8),
            outputByteCount: 12)
        let nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })
        let sealed = try AES.GCM.seal(plaintext + Data([2]), using: key, nonce: nonce)
        // RFC8188 header: 16-octet salt, network-order record size, key-id length and public point.
        return salt + Data([0, 0, 16, 0, 65]) + senderPublic + sealed.ciphertext + sealed.tag
    }
    private static func invalid() -> TractandaError {
        TractandaError("invalidProperties", "Invalid Web Push encryption parameters.")
    }
}
