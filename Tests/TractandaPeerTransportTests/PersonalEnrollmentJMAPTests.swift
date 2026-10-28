import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TractandaClient
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTLS
@testable import TractandaPeerTransport

private final class EnrollmentTestConnections: Sendable {
    let values = Mutex<[PersonalPeerConnection]>([])
    func add(_ value: PersonalPeerConnection) { values.withLock { $0.append(value) } }
    var snapshot: [PersonalPeerConnection] { values.withLock { $0 } }
}

final class PersonalEnrollmentJMAPTests: XCTestCase {
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func binding() throws -> PeerExchangeBinding {
        try .init(
            peerID: "enrollment-test", storeID: id(), localReplicaID: id(), remoteReplicaID: id(),
            pairingID: id(), localIsInitiator: true, configurationDigest: String(repeating: "a", count: 64))
    }
    private func claimRequest(operationID: String? = nil) throws -> PeerExchangeRequest {
        let metadata = PersonalEnrollmentClaimMetadata(
            operationID: try operationID ?? id(),
            targetReplicaID: try id(), targetHostname: "target.invalid", continuationPairingID: try id())
        let claim = PersonalEnrollmentClaim(
            metadata: metadata,
            continuationSecret: try .init(bytes: Array(repeating: 0x67, count: 32)))
        return .init("enrollment.claim", ["claim": .bytes(try claim.privateEncodedBytes())])
    }
    private func wire(
        _ method: String, account: String, fields: [JMAPMember] = [],
        callID: String = "enrollment", calls: Int = 1, capability: String = PersonalEnrollmentJMAP.capability
    ) throws -> Data {
        try JMAPValue.object([
            .init("using", .array([.string(capability)])),
            .init(
                "methodCalls",
                .array(
                    (0..<calls).map { _ in
                        JMAPInvocation(
                            name: method,
                            arguments: .object([.init("accountId", .string(account))] + fields),
                            callID: callID
                        ).value
                    })),
        ]).encoded()
    }
    private func response(_ result: PersonalPeerJMAP.Reply) throws -> JMAPValue {
        guard case .response(let bytes) = result else {
            throw TractandaError("testFailure", "Expected method response")
        }
        return try JMAPValue.decode(bytes)
    }
    private func error(_ result: PersonalPeerJMAP.Reply) throws -> String? {
        try response(result)["methodResponses"]?.elements?.first?.elements?[1]["type"]?.text
    }
    private func execute(
        _ data: Data, bound: PeerExchangeBinding,
        purpose: PersonalEnrollmentTransportPurpose,
        perform: (
            @Sendable (PeerExchangeBinding, PersonalEnrollmentTransportPurpose, PeerExchangeRequest)
                async throws -> Data
        )? = { _, _, _ in Data("{}".utf8) }
    ) async throws -> PersonalPeerJMAP.Reply {
        try await PersonalEnrollmentJMAP.execute(
            data, binding: bound, purpose: purpose,
            validate: { actual, actualPurpose in
                XCTAssertEqual(actual, bound)
                XCTAssertEqual(actualPurpose, purpose)
            }, perform: perform)
    }

    func testStructuredClaimRoundTripAndOnlySecretIsCanonicalBase64() async throws {
        let bound = try binding()
        let request = try claimRequest()
        let data = try PersonalEnrollmentJMAP.request(request, binding: bound, purpose: .invitation)
        let value = try JMAPValue.decode(data)
        let declaringCore = try JMAPValue.object([
            .init("using", .array([.string(JMAPKernel.core), .string(PersonalEnrollmentJMAP.capability)])),
            .init("methodCalls", try XCTUnwrap(value["methodCalls"])),
        ]).encoded()
        let withCore = try await execute(declaringCore, bound: bound, purpose: .invitation)
        XCTAssertNil(try error(withCore))
        let args = try XCTUnwrap(value["methodCalls"]?.elements?.first?.elements?[1])
        XCTAssertNotNil(args["metadata"]?.members)
        XCTAssertNil(args["claim"])
        XCTAssertEqual(
            args["continuationSecret"]?.text, Data(repeating: 0x67, count: 32).base64EncodedString())
        let result = try await execute(data, bound: bound, purpose: .invitation) { _, _, received in
            XCTAssertEqual(received.operation, "enrollment.claim")
            guard case .bytes(let receivedBytes)? = received.fields["claim"],
                case .bytes(let expectedBytes)? = request.fields["claim"]
            else { throw PersonalEnrollmentError.invalid() }
            XCTAssertEqual(receivedBytes, expectedBytes)
            return Data("{\"accepted\":true}".utf8)
        }
        guard case .response(let reply) = result else { return XCTFail("Expected response") }
        XCTAssertEqual(
            try JMAPValue.decode(PersonalEnrollmentJMAP.response(reply, request: request))["accepted"],
            .bool(true))
    }

    func testExactPurposeAllowlistsRejectCrossPurposeAndOrdinaryMethodsBeforeDomain() async throws {
        let bound = try binding()
        let called = Mutex(0)
        let methods: [(PersonalEnrollmentTransportPurpose, String)] = [
            (.memberControl, "claim"), (.memberControl, "targetStage"), (.invitation, "memberStage"),
            (.invitation, "targetStatus"), (.continuation, "claim"), (.continuation, "memberCommit"),
        ]
        for (purpose, name) in methods {
            let result = try await execute(
                wire("TractandaEnrollment/" + name, account: bound.storeID),
                bound: bound, purpose: purpose
            ) { _, _, _ in
                called.withLock { $0 += 1 }
                return Data("{}".utf8)
            }
            XCTAssertEqual(try error(result), "unknownMethod")
        }
        for purpose: PersonalEnrollmentTransportPurpose in [.invitation, .continuation] {
            let result = try await execute(
                wire("TractandaItem/get", account: bound.storeID), bound: bound,
                purpose: purpose
            ) { _, _, _ in
                called.withLock { $0 += 1 }
                return Data("{}".utf8)
            }
            XCTAssertEqual(try error(result), "unknownMethod")
        }
        let core = try await execute(
            wire("Core/echo", account: bound.storeID, capability: JMAPKernel.core),
            bound: bound, purpose: .invitation
        ) { _, _, _ in
            called.withLock { $0 += 1 }
            return Data("{}".utf8)
        }
        XCTAssertEqual(try error(core), "unknownMethod")
        let mixed = try JMAPValue.object([
            .init("using", .array([.string(JMAPKernel.core), .string(PersonalEnrollmentJMAP.capability)])),
            .init(
                "methodCalls",
                .array([
                    JMAPInvocation(
                        name: "TractandaEnrollment/claim",
                        arguments: try PersonalEnrollmentJMAP.arguments(
                            claimRequest(), accountID: bound.storeID),
                        callID: "first"
                    ).value,
                    JMAPInvocation(name: "Core/echo", arguments: .object([]), callID: "second").value,
                ])),
        ]).encoded()
        guard
            case .problem(let mixedProblem) = try await execute(
                mixed, bound: bound, purpose: .invitation,
                perform: { _, _, _ in
                    called.withLock { $0 += 1 }
                    return Data("{}".utf8)
                })
        else {
            return XCTFail("Mixed batch executed")
        }
        XCTAssertEqual(JMAPProblem.decode(mixedProblem)?.limit, "maxCallsInRequest")
        let emptyBytes = try wire(
            "Core/echo", account: bound.storeID, callID: "", capability: JMAPKernel.core
        ).count
        let large = try wire(
            "Core/echo", account: bound.storeID,
            callID: String(repeating: "x", count: PersonalEnrollmentJMAP.maximumBodyBytes - emptyBytes),
            capability: JMAPKernel.core)
        XCTAssertEqual(large.count, PersonalEnrollmentJMAP.maximumBodyBytes)
        let limited = try await execute(large, bound: bound, purpose: .invitation) { _, _, _ in
            called.withLock { $0 += 1 }
            return Data("{}".utf8)
        }
        switch limited {
        case .response(let bytes):
            XCTAssertLessThanOrEqual(bytes.count, PersonalEnrollmentJMAP.maximumBodyBytes)
        case .problem(let bytes):
            XCTAssertEqual(JMAPProblem.decode(bytes)?.limit, "tractanda.maxResponseBytes")
        }
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testForeignAccountForgedPurposeUnknownFieldsAndUIDDoNotReachHandler() async throws {
        let bound = try binding()
        let called = Mutex(0)
        let operation = try id()
        for (account, fields, expected) in [
            ("foreign", [JMAPMember("operationID", .string(operation))], "accountNotFound"),
            (
                bound.storeID,
                [.init("operationID", .string(operation)), .init("purpose", .string("memberControl"))],
                "invalidArguments"
            ),
            (
                bound.storeID,
                [.init("operationID", .string(operation)), .init("uid", .number(try JMAPNumber("0")))],
                "invalidArguments"
            ),
            (
                bound.storeID, [.init("operationID", .string(operation)), .init("paths", .array([]))],
                "invalidArguments"
            ),
        ] {
            let result = try await execute(
                wire("TractandaEnrollment/targetStatus", account: account, fields: fields),
                bound: bound, purpose: .continuation
            ) { _, _, _ in
                called.withLock { $0 += 1 }
                return Data("{}".utf8)
            }
            XCTAssertEqual(try error(result), expected)
        }
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testMalformedDuplicateAndUnboundedClaimAreRejectedWithoutEffects() async throws {
        let bound = try binding()
        let called = Mutex(0)
        let valid = try PersonalEnrollmentJMAP.arguments(claimRequest(), accountID: bound.storeID)
        for secret in [
            String(repeating: "!", count: 44), "Zg==", Data(repeating: 0, count: 33).base64EncodedString(),
        ] {
            let fields =
                valid.members!.filter { $0.name != "accountId" && $0.name != "continuationSecret" }
                + [.init("continuationSecret", .string(secret))]
            let result = try await execute(
                wire("TractandaEnrollment/claim", account: bound.storeID, fields: fields),
                bound: bound, purpose: .invitation
            ) { _, _, _ in
                called.withLock { $0 += 1 }
                return Data("{}".utf8)
            }
            XCTAssertEqual(try error(result), "invalidArguments")
        }
        for data in [
            Data("{".utf8), Data(repeating: 0, count: PersonalEnrollmentJMAP.maximumBodyBytes + 1),
            Data("{\"using\":[],\"using\":[],\"methodCalls\":[]}".utf8),
        ] {
            guard
                case .problem = try await execute(
                    data, bound: bound, purpose: .invitation,
                    perform: { _, _, _ in
                        called.withLock { $0 += 1 }
                        return Data("{}".utf8)
                    })
            else {
                return XCTFail("Expected request problem")
            }
        }
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testOneEnrollmentMutationPerRequestAndDisabledHandlerPreflight() async throws {
        let bound = try binding()
        let called = Mutex(0)
        guard
            case .problem(let problem) = try await execute(
                wire("TractandaEnrollment/memberStage", account: bound.storeID, calls: 2),
                bound: bound, purpose: .memberControl,
                perform: { _, _, _ in
                    called.withLock { $0 += 1 }
                    return Data("{}".utf8)
                })
        else {
            return XCTFail("Expected request limit")
        }
        XCTAssertEqual(JMAPProblem.decode(problem)?.limit, "maxCallsInRequest")
        let disabled = try await execute(
            wire(
                "TractandaEnrollment/memberInspect", account: bound.storeID,
                fields: [.init("operationID", .string(try id()))]), bound: bound, purpose: .memberControl,
            perform: nil)
        guard case .problem(let unsupported) = disabled else {
            return XCTFail("Disabled capability was exposed")
        }
        XCTAssertEqual(JMAPProblem.decode(unsupported)?.type, "urn:ietf:params:jmap:error:unknownCapability")
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testMutationReplyReservationPrecedesSideEffectsForLongCorrelation() async throws {
        let bound = try binding()
        let called = Mutex(0)
        let result = try await execute(
            wire(
                "TractandaEnrollment/targetFinish", account: bound.storeID,
                fields: [.init("operationID", .string(try id()))],
                callID: String(repeating: "x", count: 150 * 1024)),
            bound: bound, purpose: .continuation
        ) { _, _, _ in
            called.withLock { $0 += 1 }
            return Data("{}".utf8)
        }
        XCTAssertEqual(try error(result), "responseTooLarge")
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testConsumedInvitationCanReturnCommittedClaimButCannotClaimAgain() async throws {
        let bound = try binding()
        let live = Mutex(true)
        let request = try claimRequest()
        let data = try PersonalEnrollmentJMAP.request(request, binding: bound, purpose: .invitation)
        let validate:
            @Sendable (PeerExchangeBinding, PersonalEnrollmentTransportPurpose) async throws -> Void = {
                _, _ in
                guard live.withLock({ $0 }) else { throw TractandaError("untrustedPeer", "Consumed") }
            }
        let result = try await PersonalEnrollmentJMAP.execute(
            data, binding: bound, purpose: .invitation,
            validate: validate,
            perform: { _, _, _ in
                live.withLock { $0 = false }
                return Data("{\"accepted\":true}".utf8)
            })
        guard case .response(let bytes) = result else { return XCTFail("Committed claim lost reply") }
        XCTAssertNoThrow(try PersonalEnrollmentJMAP.response(bytes, request: request))
        do {
            _ = try await PersonalEnrollmentJMAP.execute(
                data, binding: bound, purpose: .invitation,
                validate: validate,
                perform: { _, _, _ in
                    XCTFail("Consumed key reached handler")
                    return Data()
                })
            XCTFail("Consumed key admitted")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "untrustedPeer") }
    }

    func testStructuredMemberDecisionPayloadAndPrivateCredentialBound() async throws {
        let bound = try binding()
        let operation = try id()
        let called = Mutex(0)
        let request = PeerExchangeRequest(
            "enrollment.member.stage",
            [
                "operationID": .text(operation),
                "decision": .bytes(Data("{\"operationID\":\"test\"}".utf8)),
                "payload": .bytes(Data("{\"privateCredentials\":[\"AQID\"]}".utf8)),
            ])
        let wire = try PersonalEnrollmentJMAP.request(request, binding: bound, purpose: .memberControl)
        let result = try await execute(wire, bound: bound, purpose: .memberControl) { _, _, received in
            called.withLock { $0 += 1 }
            guard case .bytes(let payload)? = received.fields["payload"] else {
                throw PersonalEnrollmentError.invalid()
            }
            XCTAssertNotNil(try JMAPValue.decode(payload)["privateCredentials"]?.elements)
            return Data("{}".utf8)
        }
        XCTAssertNil(try error(result))
        XCTAssertEqual(called.withLock { $0 }, 1)
        XCTAssertEqual(PersonalEnrollmentJMAP.maximumPrivateCredentialCount, 30)
        for count in [30, 31] {
            let credentials = JMAPValue.object([
                .init(
                    "privateCredentials",
                    .array(
                        (0..<count).map { _ in
                            .string(Data(repeating: 0x67, count: 32).base64EncodedString())
                        }))
            ])
            let bounded = try await execute(
                self.wire(
                    "TractandaEnrollment/memberStage", account: bound.storeID,
                    fields: [
                        .init("operationID", .string(operation)), .init("decision", .object([])),
                        .init("payload", credentials),
                    ]),
                bound: bound, purpose: .memberControl
            ) { _, _, _ in
                called.withLock { $0 += 1 }
                return Data("{}".utf8)
            }
            XCTAssertEqual(try error(bounded), count == 30 ? nil : "invalidArguments")
        }
        XCTAssertEqual(called.withLock { $0 }, 2)
        let oversized = JMAPValue.object([
            .init(
                "privateCredentials",
                .array([
                    .string(
                        Data(repeating: 0, count: PersonalEnrollmentJMAP.maximumPrivateCredentialsBytes + 1)
                            .base64EncodedString())
                ]))
        ])
        let rejected = try await execute(
            self.wire(
                "TractandaEnrollment/memberStage", account: bound.storeID,
                fields: [
                    .init("operationID", .string(operation)), .init("decision", .object([])),
                    .init("payload", oversized),
                ]),
            bound: bound, purpose: .memberControl
        ) { _, _, _ in
            called.withLock { $0 += 1 }
            return Data("{}".utf8)
        }
        XCTAssertEqual(try error(rejected), "invalidArguments")
        XCTAssertEqual(called.withLock { $0 }, 2)
    }

    func testPrivateErrorsAreSanitizedAndReplyCorrelationIsExact() async throws {
        let bound = try binding()
        let request = PeerExchangeRequest("enrollment.member.inspect", ["operationID": .text(try id())])
        let result = try await execute(
            PersonalEnrollmentJMAP.request(request, binding: bound, purpose: .memberControl),
            bound: bound, purpose: .memberControl
        ) { _, _, _ in throw TractandaError("secret-value", "secret-value") }
        let value = try response(result)
        XCTAssertEqual(try error(result), "serverFail")
        let actionable = [
            "enrollmentCapacityUnsupported", "enrollmentTopologyUnsupported", "configurationDrift",
            "baselineNotReady", "invitationExpired", "membersOffline", "membershipConflict", "resourceLimit",
            "enrollmentPersistenceUncertain", "principalMappingChanged", "invalidEnrollmentTarget",
        ]
        for code in actionable {
            let preserved = try await execute(
                PersonalEnrollmentJMAP.request(request, binding: bound, purpose: .memberControl),
                bound: bound, purpose: .memberControl
            ) { _, _, _ in throw TractandaError(code, "secret-value") }
            XCTAssertEqual(try error(preserved), code)
            guard case .response(let bytes) = preserved else {
                return XCTFail("Expected bounded action error")
            }
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret-value"))
            do {
                _ = try PersonalEnrollmentJMAP.response(bytes, request: request)
                XCTFail("Action error succeeded")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, code) }
        }
        XCTAssertFalse(String(decoding: try value.encoded(), as: UTF8.self).contains("secret-value"))
        let mutation = PeerExchangeRequest("enrollment.target.finish", ["operationID": .text(try id())])
        let partial = try await execute(
            PersonalEnrollmentJMAP.request(mutation, binding: bound, purpose: .continuation),
            bound: bound, purpose: .continuation
        ) { _, _, _ in throw TractandaError("secret-value", "secret-value") }
        XCTAssertEqual(try error(partial), "serverPartialFail")
        guard case .response(let partialBytes) = partial else {
            return XCTFail("Expected partial failure response")
        }
        do {
            _ = try PersonalEnrollmentJMAP.response(partialBytes, request: mutation)
            XCTFail("Partial failure succeeded")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "serverPartialFail") }
        XCTAssertFalse(String(decoding: partialBytes, as: UTF8.self).contains("secret-value"))
        for (name, correlation) in [
            ("TractandaEnrollment/memberInspect", "wrong"), ("TractandaEnrollment/jobStatus", "enrollment"),
        ] {
            let bad = try JMAPValue.object([
                .init("sessionState", .string("test")),
                .init(
                    "methodResponses",
                    .array([JMAPInvocation(name: name, arguments: .object([]), callID: correlation).value])),
            ]).encoded()
            XCTAssertThrowsError(try PersonalEnrollmentJMAP.response(bad, request: request))
        }
    }

    func testPairingResolutionRequiresExactHostPurpose() throws {
        let bound = try binding()
        let profile = try PeerTLSProfile(
            storeID: bound.storeID, initiatorReplicaID: bound.localReplicaID,
            responderReplicaID: bound.remoteReplicaID, pairingID: bound.pairingID,
            purpose: .enrollmentInvitation)
        let pairing = try PeerPairing(
            peerID: "private", profile: profile, role: .initiator,
            configurationDigest: bound.configurationDigest,
            secret: .init(bytes: Array(repeating: 0x67, count: 32)))
        let session = PeerTLSSession(profile: profile, role: .initiator)
        XCTAssertThrowsError(try pairing.resolve(session))
        XCTAssertThrowsError(try pairing.resolve(session, expectedPurpose: .enrollmentContinuation))
        XCTAssertNoThrow(try pairing.resolve(session, expectedPurpose: .enrollmentInvitation))
    }

    func testPurposeTLSInvitationUsesOnePrivateSocketForDuplexAndRejectsContent() async throws {
        try await purposeSocket(.enrollmentInvitation, expected: .invitation)
    }
    func testPurposeTLSContinuationUsesOnePrivateSocketForDuplexAndRejectsMemberControl() async throws {
        try await purposeSocket(.enrollmentContinuation, expected: .continuation)
    }
    func testPurposeTLSMemberSupportsEnrollmentAlongsideUnchangedOrdinaryWire() async throws {
        try await purposeSocket(.peer, expected: .memberControl)
    }
    private func purposeSocket(
        _ tlsPurpose: PeerTLSProfile.Purpose,
        expected: PersonalEnrollmentTransportPurpose
    ) async throws {
        // Private Unix socket only; payloads are in memory, no stores or live listeners.
        let bound = try binding()
        let profile = try PeerTLSProfile(
            storeID: bound.storeID, initiatorReplicaID: bound.localReplicaID,
            responderReplicaID: bound.remoteReplicaID, pairingID: bound.pairingID, purpose: tlsPurpose)
        let client = try PeerPairing(
            peerID: "out", profile: profile, role: .initiator,
            configurationDigest: bound.configurationDigest,
            secret: .init(bytes: Array(repeating: 0x67, count: 32)))
        let server = try PeerPairing(
            peerID: "in", profile: profile, role: .responder,
            configurationDigest: bound.configurationDigest,
            secret: .init(bytes: Array(repeating: 0x67, count: 32)))
        let normalCalls = Mutex(0)
        let enrollmentCalls = Mutex(0)
        let operations = PersonalPeerOperations(
            validate: { _ in
                XCTAssertEqual(expected, .memberControl)
            },
            handle: { _, _ in
                normalCalls.withLock { $0 += 1 }
                return Data("{\"ready\":true}".utf8)
            },
            enrollmentValidate: { _, purpose in XCTAssertEqual(purpose, expected) },
            enrollmentHandle: { _, purpose, _ in
                XCTAssertEqual(purpose, expected)
                enrollmentCalls.withLock { $0 += 1 }
                return Data("{\"accepted\":true}".utf8)
            })
        let directory = URL(fileURLWithPath: "/tmp/trac121-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("peer.sock").path
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let accepted = EnrollmentTestConnections()
        let installed = EnrollmentTestConnections()
        // One explicitly installed responder holds mixed contexts. The authenticated TLS
        // selection, rather than request fields, selects the actual dispatch purpose.
        let extraProfile = try PeerTLSProfile(
            storeID: bound.storeID, initiatorReplicaID: bound.localReplicaID,
            responderReplicaID: bound.remoteReplicaID, pairingID: id(),
            purpose: tlsPurpose == .peer ? .enrollmentInvitation : .peer)
        let extra = try PeerPairing(
            peerID: "other-purpose", profile: extraProfile, role: .responder,
            configurationDigest: bound.configurationDigest,
            secret: .init(bytes: Array(repeating: 0x78, count: 32)))
        let responder = try PeerExchangeResponder(pairings: [server, extra])
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            PersonalPeerConnection.install(on: channel, responder: responder, operations: operations).map {
                accepted.add($0)
            }
        }.bind(unixDomainSocketPath: socket).get()
        defer {
            try? await listener.close().get()
            for connection in installed.snapshot + accepted.snapshot { try? await connection.close().get() }
        }
        _ = try await ClientBootstrap(group: group).channelInitializer { channel in
            PersonalPeerConnection.install(on: channel, pairing: client, operations: operations).map {
                installed.add($0)
            }
        }.connect(unixDomainSocketPath: socket).get()
        let left = try XCTUnwrap(installed.snapshot.first)
        _ = try await left.ready.get()
        let right = try XCTUnwrap(accepted.snapshot.first)
        _ = try await right.ready.get()
        let request: PeerExchangeRequest
        switch expected {
        case .invitation: request = try claimRequest()
        case .continuation: request = .init("enrollment.target.status", ["operationID": .text(try id())])
        case .memberControl: request = .init("enrollment.member.inspect", ["operationID": .text(try id())])
        }
        async let one = left.request(request).get()
        async let two = right.request(request).get()
        let results = try await (one, two)
        XCTAssertEqual(try JMAPValue.decode(results.0)["accepted"], .bool(true))
        XCTAssertEqual(try JMAPValue.decode(results.1)["accepted"], .bool(true))
        XCTAssertEqual(enrollmentCalls.withLock { $0 }, 2)
        if expected == .memberControl {
            _ = try await left.request(.init("personal.sync.ready")).get()
            XCTAssertEqual(normalCalls.withLock { $0 }, 1)
        } else {
            do {
                _ = try await left.request(.init("personal.sync.ready")).get()
                XCTFail("Content crossed enrollment purpose")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "unsupportedPeerOperation") }
            do {
                _ = try await left.request(
                    .init("enrollment.member.inspect", ["operationID": .text(try id())])
                ).get()
                XCTFail("Member crossed enrollment purpose")
            } catch { XCTAssertEqual((error as? JMAPMethodError)?.type, "unknownMethod") }
            XCTAssertEqual(normalCalls.withLock { $0 }, 0)
        }
    }
}
