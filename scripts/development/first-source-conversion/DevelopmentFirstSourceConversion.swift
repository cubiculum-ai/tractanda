import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore

/// This type exists only in the development TEST target. No installed executable links it.
enum DevelopmentFirstSourceConversion {
    static func run(root: URL, accounts: any AccountDirectory, actorUID: UInt32, operationID: String,
                    limits: InitialAuthorityBootstrap.Limits = .init(),
                    progress: ((String) throws -> Void)? = nil) throws {
        try limits.validate()
        let request: InitialAuthorityBootstrap.Request
        if let old = try InitialAuthorityBootstrap.load(root: root) {
            guard old.operationID == operationID, old.actorUID == actorUID,
                old.inventory != nil, old.limits == limits else {
                throw TractandaError("firstSourceConflict", "Stopped conversion inputs differ from its receipt.")
            }
            request = old
            // Before constructor capture on retry: identity, paths, bytes, permissions, caps.
            try InitialAuthorityBootstrap.validateOriginalInventory(root: root, request: old,
                progress: { try progress?("preflight") })
        } else {
            var ordinary: ItemStore? = try ItemStore(root: root, accounts: accounts,
                revisionProjectionEnabled: true)
            request = try ordinary!.prepareInitialAuthorityConversion(operationID: operationID,
                actorUID: actorUID, limits: limits, progress: { try progress?("preflight") })
            ordinary = nil // Release the ordinary lifetime writer BEFORE authority-aware capture.
        }
        try progress?("beforeAuthorityOpen")
        let authority = try ItemStore(root: root, accounts: accounts,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: request)
        try authority.finishInitialAuthority(request, progress: progress)
    }
}

final class DevelopmentFirstSourceConversionTests: XCTestCase {
    /// Default swift test skips this entry. A root, operation, current administrator and explicit
    /// stopped-maintenance acknowledgment are all required; no production discovery exists.
    func testRunExplicitStoppedConversion() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TRACTANDA_DEV_FIRST_SOURCE_STOPPED"] == "YES",
            let root = env["TRACTANDA_DEV_FIRST_SOURCE_ROOT"],
            let operation = env["TRACTANDA_DEV_FIRST_SOURCE_OPERATION"],
            let uidText = env["TRACTANDA_DEV_FIRST_SOURCE_UID"], let uid = UInt32(uidText)
        else { throw XCTSkip("Explicit stopped-development conversion is not requested.") }
        guard root.hasPrefix("/"), root != "/" else {
            throw TractandaError("invalidStore", "Development conversion requires an absolute dedicated root.")
        }
        var limits = InitialAuthorityBootstrap.Limits()
        if let value = env["TRACTANDA_DEV_FIRST_SOURCE_RECORDS"] { limits.maximumRecords = try integer(value) }
        if let value = env["TRACTANDA_DEV_FIRST_SOURCE_BYTES"] { limits.maximumBytes = try integer(value) }
        if let value = env["TRACTANDA_DEV_FIRST_SOURCE_WORK"] { limits.maximumWork = try integer(value) }
        try DevelopmentFirstSourceConversion.run(root: URL(fileURLWithPath: root),
            accounts: SystemAccountDirectory(), actorUID: uid, operationID: operation, limits: limits)
    }
    private func integer(_ value: String) throws -> Int {
        guard let result = Int(value), result > 0 else { throw TractandaError("resourceLimit", "Invalid explicit limit.") }
        return result
    }
}
