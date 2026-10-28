import Foundation
import TractandaCore

/// Read-only, account-aware native API. A stopped server remains stopped.
@discardableResult
func clusterStatusCommand(
    arguments: [String], options: ConnectionOptions,
    output: (Data) -> Void = { print(String(decoding: $0, as: UTF8.self)) },
    sendForTesting: CLIRequestSender? = nil
) throws -> Bool {
    guard arguments.first == "cluster" else { return false }
    guard arguments == ["cluster", "status"] || arguments == ["cluster", "status", "--json"] else {
        throw TractandaError("usage", "Use tractanda [--profile NAME | --socket PATH] cluster status [--json].")
    }
    var selected = options
    selected.startsService = false
    let bytes = try call(selected.resolve(), PeerOperatorStatus.nativeMethod, [:], sendForTesting: sendForTesting)
    // NativeMethodResult already bounds the envelope. Its generic unwrap pretty-prints;
    // account for this status DTO in its actual compact wire representation instead.
    let status = try JSON.decode(PeerOperatorStatus.self, bytes)
    let encoded = try status.encoded()
    guard encoded.count <= PeerOperatorStatus.maximumResponseBytes else {
        throw TractandaError("resourceLimit", "Cluster status response exceeds its bound.")
    }
    output(arguments.last == "--json" ? encoded : Data(clusterStatusText(status).utf8))
    return true
}

func clusterStatusText(_ status: PeerOperatorStatus) -> String {
    // JSON already escapes controls; text must also be safe on an operator's terminal.
    func safe(_ value: String?) -> String {
        guard let value else { return "unknown" }
        return String(String.UnicodeScalarView(value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(0xfffd)! : $0
        }))
    }
    let canonical = status.canonical
    let runtime = status.runtime
    var lines = [
        "Store: \(safe(canonical.storeID))",
        "Local replica: \(safe(canonical.replicaID))",
        "Local readiness: \(canonical.readiness.rawValue)",
        "Local runtime: \(runtime.state.rawValue); synchronization: \(runtime.synchronization.state.rawValue)",
        "Loaded configuration: \(safe(runtime.configurationPath)); digest: \(safe(runtime.settingsDigest))",
    ]
    if let personal = canonical.personal {
        lines.append("Current membership: \(safe(personal.currentMembershipDigest))")
        if let membership = personal.currentMembership {
            for member in membership.members.sorted(by: { $0.replicaID < $1.replicaID }) {
                let local = member.replicaID == canonical.replicaID
                lines.append("  \(safe(member.hostname))  \(safe(member.replicaID))\(local ? " (local)" : "")")
                if !local {
                    let matching = runtime.personalPeers?.filter {
                        $0.replicaID == member.replicaID && $0.configurationDigest == personal.currentMembershipDigest
                    } ?? []
                    if matching.isEmpty { lines.append("    Observed connection: unknown") }
                    for observation in matching { append(observation, to: &lines, safe: safe) }
                }
            }
        } else { lines.append("  Standalone: no current cluster membership") }
        if let pending = personal.pendingMembership {
            lines.append("Pending proposal (not current membership): \(safe(personal.pendingMembershipDigest))")
            for member in pending.members {
                lines.append("  \(safe(member.hostname))  \(safe(member.replicaID))")
            }
            lines.append("  Required online: \(personal.requiredOnlineReplicaIDs.map { safe($0) }.joined(separator: ", "))")
        } else { lines.append("Pending proposal: none") }
        lines.append("Local baseline: \(personal.baselineSourceReplicaID.map { "pending; source " + safe($0) } ?? "none pending")")
        let current = personal.currentMembershipDigest
        for observation in runtime.personalPeers ?? [] where observation.configurationDigest != current {
            let label = observation.configurationDigest == personal.pendingMembershipDigest ? "pending proposal" : "stale/other configuration"
            lines.append("Observation for \(safe(observation.replicaID)) (\(label), \(safe(observation.configurationDigest))):")
            append(observation, to: &lines, safe: safe)
        }
    } else { lines.append("Personal cluster configuration: unavailable") }
    if let peers = runtime.configuredPeers {
        lines.append("Loaded local routes (do not establish membership):")
        for peer in peers {
            lines.append("  \(safe(peer.alias)): " + peer.endpoints.map { "\(safe($0.host)):\($0.port)" }.joined(separator: ", "))
        }
        if peers.isEmpty { lines.append("  none") }
    } else { lines.append("Loaded local routes: unknown") }
    lines.append("Local runtime error: \(safe(runtime.lastErrorCode))")
    lines.append("Observations are process-local; absent timestamps are unknown. Connected sockets are duplex; incoming/outgoing identify only the initiator.")
    lines.append("A connection or completed finite cut does not establish remote store health, baseline readiness, or cluster convergence.")
    return lines.joined(separator: "\n") + "\n"
}

private func append(_ value: PersonalPeerObservation, to lines: inout [String], safe: (String?) -> String) {
    lines.append("    Observed connection: \(value.connected ? "connected" : "disconnected"); incoming \(value.incomingConnectionCount), outgoing \(value.outgoingConnectionCount); \(value.controlOnly.map { $0 ? "control-only" : "data-capable" } ?? "mode unknown")")
    lines.append("    Pull: \(value.pullRunning ? "running" : "idle"); completed finite cuts: \(value.completedCuts); last outcome: \(value.lastOutcome?.rawValue ?? "unknown")")
    if let progress = value.currentPull {
        lines.append("    Current pull: \(progress.phase.rawValue); \(progress.revisionCount) revisions processed; \(progress.transferredBytes) bytes transferred; last progress: \(safe(progress.lastProgressAt))")
    }
    lines.append("    Connected at: \(safe(value.lastConnectedAt)); disconnected at: \(safe(value.lastDisconnectedAt))")
    lines.append("    Pull started: \(safe(value.lastPullStartedAt)); finished: \(safe(value.lastPullFinishedAt))")
    if let revisions = value.lastRevisionCount, let bytes = value.lastTransferredBytes {
        lines.append("    Last completed cut: \(revisions) revisions; \(bytes) transferred bytes; outcomes " + value.lastRevisionOutcomes.keys.sorted().map { "\($0)=\(value.lastRevisionOutcomes[$0]!)" }.joined(separator: ", "))
    }
    lines.append("    Last error: \(safe(value.lastErrorCode)); at: \(safe(value.lastErrorAt))")
}
