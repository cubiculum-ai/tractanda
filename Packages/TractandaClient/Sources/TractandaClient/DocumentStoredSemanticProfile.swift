/// Stored page meaning is independent of the producer's build/model provenance.
/// Cases project existing parser/preprocessing fields; no new wire field is added.
public enum DocumentStoredSemanticProfile: Equatable, Sendable {
    case contentCropV2
    case legacyCanvasV1
}
