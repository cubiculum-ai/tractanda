/// Versioned native behavior contracts. Presence declares API support, not configuration or permission.
public enum ServerFeature: String, Sendable {
    case asynchronousStoreRebuild = "tractanda.store-rebuild.v2"
    case runtimeIdentity = "tractanda.runtime-identity.v1"
    case semanticJobTiming = "tractanda.semantic-job-timing.v1"
    case categoryMembershipSort = "tractanda.category-membership-sort.v1"
    case categoryMembershipProjection = "tractanda.category-membership-projection.v1"
    case extractedTextDiagnostics = "tractanda.extracted-text.v1"
    case extractedTextUnits = "tractanda.extracted-text-units.v1"
    case attachmentText = "tractanda.attachment-text.v1"
    case documentJobs = "tractanda.document-jobs.v1"
    case attachmentDocumentContent = "tractanda.attachment-document-content.v2"
    case attachmentDocument = "tractanda.attachment-document.v1"
    case resumableAttachmentTransfer = "tractanda.attachment-transfer.v2"
    case attachmentLifecycle = "tractanda.attachment-lifecycle.v1"
    case liveSeekCursor = "tractanda.live-seek-cursor.v1"
}
