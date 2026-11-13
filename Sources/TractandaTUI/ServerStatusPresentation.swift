import Foundation
import TractandaCore

/// Read-only observations from the selected local server. Each section can fail independently.
enum ServerStatusPresentation {
    static func text(client: ItemClient, shouldContinue: () -> Bool = { true }) -> String {
        func safe(_ value: String?) -> String {
            guard let value else { return "unknown" }
            return String(
                String.UnicodeScalarView(
                    value.unicodeScalars.map {
                        CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(0xfffd)! : $0
                    }))
        }
        func object(_ method: String) throws -> [String: Any] {
            guard let result = try JSONSerialization.jsonObject(with: client.call(method)) as? [String: Any]
            else { throw TractandaError("invalidResponse", "Invalid status response") }
            return result
        }
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        var lines = [
            "Read-only local observations · R refreshes · Esc closes", "Requested at: \(capturedAt)", "",
        ]
        do {
            let info = try object("TractandaStore/info")
            let server = info["server"] as? [String: Any]
            lines.append("Server version: \(safe(server?["version"] as? String))")
        } catch { lines.append("Server info unavailable: \(safe(String(describing: error)))") }
        if !shouldContinue() { return "" }
        do {
            let semantic = try object("TractandaSemantic/status")
            let indexed = (semantic["indexedItems"] as? Int).map(String.init) ?? "unknown"
            let indexable = (semantic["indexableItems"] as? Int).map(String.init) ?? "unknown"
            let pending = (semantic["pendingItems"] as? Int).map(String.init) ?? "unknown"
            lines.append(
                "Semantic index: \(safe(indexed))/\(safe(indexable)) indexed; \(safe(pending)) pending; \(safe(semantic["coverage"] as? String))"
            )
        } catch { lines.append("Semantic index unavailable: \(safe(String(describing: error)))") }
        if !shouldContinue() { return "" }
        do {
            let peer = try JSON.decode(PeerOperatorStatus.self, client.call(PeerOperatorStatus.nativeMethod))
            lines += [
                "", "Store: \(safe(peer.canonical.storeID))",
                "Local replica: \(safe(peer.canonical.replicaID))",
                "Readiness: \(peer.canonical.readiness.rawValue)",
                "Runtime: \(peer.runtime.state.rawValue); synchronization: \(peer.runtime.synchronization.state.rawValue)",
            ]
            if let members = peer.canonical.personal?.currentMembership?.members {
                lines.append("Current cluster members:")
                for member in members.sorted(by: { $0.replicaID < $1.replicaID }) {
                    lines.append(
                        "  \(safe(member.hostname)) · \(safe(member.replicaID))\(member.replicaID == peer.canonical.replicaID ? " (local)" : "")"
                    )
                    let matching = (peer.runtime.personalPeers ?? []).filter {
                        $0.replicaID == member.replicaID
                            && $0.configurationDigest == peer.canonical.personal?.currentMembershipDigest
                    }
                    if member.replicaID != peer.canonical.replicaID && matching.isEmpty {
                        lines.append("    Observation: unknown")
                    }
                    for observation in matching {
                        lines.append(
                            "    \(observation.connected ? "connected" : "disconnected"); pull \(observation.pullRunning ? "running" : "idle"); completed cuts \(observation.completedCuts)"
                        )
                        if let progress = observation.currentPull {
                            lines.append(
                                "    Pull: \(progress.phase.rawValue); \(progress.revisionCount) revisions; \(progress.transferredBytes) bytes; progress: \(safe(progress.lastProgressAt))"
                            )
                        }
                        lines.append(
                            "    Last outcome: \(observation.lastOutcome?.rawValue ?? "unknown"); finished: \(safe(observation.lastPullFinishedAt))"
                        )
                        lines.append(
                            "    Last recorded error: \(safe(observation.lastErrorCode)); at: \(safe(observation.lastErrorAt))"
                        )
                    }
                }
            } else {
                lines.append("Current cluster membership: unavailable or standalone")
            }
            lines.append("Observations are local to this process and do not prove cluster convergence.")
        } catch { lines.append("Cluster status unavailable: \(safe(String(describing: error)))") }
        return lines.joined(separator: "\n")
    }
}
