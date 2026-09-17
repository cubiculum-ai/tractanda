/// Versioned native behavior contracts. Presence declares API support, not configuration or permission.
public enum ServerFeature: String, Sendable {
    case runtimeIdentity = "tractanda.runtime-identity.v1"
    case semanticJobTiming = "tractanda.semantic-job-timing.v1"
    case categoryMembershipSort = "tractanda.category-membership-sort.v1"
    case categoryMembershipProjection = "tractanda.category-membership-projection.v1"
    case extractedTextDiagnostics = "tractanda.extracted-text.v1"
}
