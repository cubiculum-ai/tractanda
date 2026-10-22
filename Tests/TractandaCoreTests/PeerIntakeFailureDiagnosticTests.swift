import XCTest

@testable import TractandaCore

final class PeerIntakeFailureDiagnosticTests: XCTestCase {
    func testKnownResourceLimitMessagesMapToBoundedCauses() {
        let cases: [(String, String, String)] = [
            ("resourceLimit", "Admission exhausted the owning operation read budget.", "admissionReadBudget"),
            (
                "resourceLimit", "Authority operation hydration allowance exhausted.",
                "authorityHydrationAllowance"
            ),
            ("resourceLimit", "Affected-item metadata exceeds operation allowance.", "affectedItemMetadata"),
            ("resourceLimit", "Catalogue statement work budget exceeded.", "catalogueVM"),
            ("resourceLimit", "Revision catalogue work budget exceeded.", "catalogueVM"),
        ]

        for (code, message, expected) in cases {
            XCTAssertEqual(PeerIntakeFailureDiagnostic.resourceCause(code: code, message: message), expected)
        }
    }

    func testUnknownOrUntrustedErrorMessageIsNotCopiedIntoDiagnostic() throws {
        let secret = "/private/user/content/credential=do-not-log"
        let error = TractandaError("resourceLimit", "Unknown limit: \(secret)")
        let record = PeerIntakeFailureDiagnostic.record(
            packageID: "package-id", phase: "reducingAffectedAuthority", error: error)

        XCTAssertEqual(record["code"] as? String, "resourceLimit")
        XCTAssertEqual(record["phase"] as? String, "reducingAffectedAuthority")
        XCTAssertNil(record["resourceCause"])
        XCTAssertNil(record["message"])
        let encoded = try JSONSerialization.data(withJSONObject: record)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains(secret))
    }

    func testCauseRequiresResourceLimitCodeAndExactWhitelistedMessage() {
        XCTAssertNil(
            PeerIntakeFailureDiagnostic.resourceCause(
                code: "invalidAuthority", message: "Admission exhausted the owning operation read budget."))
        XCTAssertNil(
            PeerIntakeFailureDiagnostic.resourceCause(
                code: "resourceLimit",
                message: "Admission exhausted the owning operation read budget. /private/secret"))
    }
}
