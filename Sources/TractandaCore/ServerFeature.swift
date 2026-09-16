/// Versioned native behavior contracts. Presence declares API support, not configuration or permission.
public enum ServerFeature: String, Sendable {
    case runtimeIdentity = "tractanda.runtime-identity.v1"
    case semanticJobTiming = "tractanda.semantic-job-timing.v1"
}
