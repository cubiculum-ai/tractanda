# Historical authority integration tests

The current fresh-store factory creates the personal/workgroup profile. Its peer access follows current membership and credentials; ordinary item history and recovery do not depend on atomic acceptance receipts, permanent retirement histories or an authorization ledger. Calling the retained metadata-audit intake configuration, credential rotation or retirement APIs on that profile must return `peerIntakeDisabled` without changing any store files or modes. `RetiredAuthorityEntryPointTests` checks those three refused operations against actual current stores and retained item histories.

The following 14 positive integration tests exercised the earlier metadata-audit protocol. They are preserved exactly at commit `d520f9979f7b0d2887d8df48d6275ef0a77d910e`, before the current test-contract reconciliation. They are removed from the current suite because enabling that protocol on a current fresh store would violate the selected product contract. No production API was enabled to make them pass. Lower-level retained atomic format, codec, index, validation, local-write and framing tests remain active.

## AtomicAuthorityRecoveryTests.swift

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaCoreTests/AtomicAuthorityRecoveryTests.swift)

- `testAcceptedForeignAndLocalHistorySurviveAppliedCleanupAndIndexOnlyDeletion`
- `testCurrentMappingDeniedHistoryRemainsHeldAfterColdRebuildWithAcceptedForeignRoot`
- `testInterruptedAcceptedRestoreRetriesSameCanonicalStoreWithoutChangingReceipts`
- `testPreviouslyAdmittedHistorySurvivesMappingLossButCurrentAndHistoryReadsAreDenied`
- `testPreparedPositiveForGenuineHeldOriginalCannotBecomeAcceptedOnColdRecovery`

## AtomicAuthorityReplicationTests.swift

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaCoreTests/AtomicAuthorityReplicationTests.swift)

- `testActualAtomicRevisionTransfersThroughNativeGatewayAndExactRetry`
- `testActualLocalWriteInterleavesWithPrivateAdmissionWithoutForkOrLostRevision`
- `testForeignSourceDecisionDoesNotGrantReceiverMappingDeniedWriteOrHistory`
- `testOriginalActorGroupChangeAfterValidationReplansBeforeAcceptedSeal`
- `testPolicyRevocationPublishesLocalNegativeThroughBoundedOutsidePeerSteps`
- `testSourceCutCannotTurnUnadmittedPositiveQueueEntryIntoLocalGrant`

## AtomicAuthorityContextSnapshotTests.swift

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaCoreTests/AtomicAuthorityContextSnapshotTests.swift)

- `testRealCanonicalAdmissionAndRetirementRootsAreCapturedWithoutCredentialExport`

## AtomicAuthorityProducerTests.swift

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaCoreTests/AtomicAuthorityProducerTests.swift)

- `testRetirementUsesAtomicPREAndPreservesExactLifecycleRetryAfterColdRebuild`

## AtomicAuthorityReviewTests.swift

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaCoreTests/AtomicAuthorityReviewTests.swift)

- `testSharedAdministratorAtomicReviewReplicatesActualResolutionWithoutNewLocalOpinion`

## Current invariant coverage

The current tests retain the useful content, permission, retry and recovery invariants through the current personal protocol:

| Invariant | Current tests |
| --- | --- |
| Current ACL controls all history after reopen/index loss | `PersonalWorkgroupStoreTests.testCurrentACLRevocationAndLocalPolicySurviveRebuild`; `PersonalDAGTests.testCommittedContentConflictRebuildsWithCurrentACLAndEveryBranchAfterIndexLoss` |
| Acknowledged content and selected histories survive disposable-index loss | `PersonalWorkgroupStoreTests.testAcknowledgedOwnedContentSurvivesAbruptProcessExitAndDisposableIndexLoss`; `testSelectedMergeHistoryOwnedDocumentAndOldPolicyItemRemainOrdinaryContent` |
| Revoked offline authors are reviewed under current permissions; explicit baseline differs from live intake | `PersonalSyncTests.testRevokedOfflineAuthorStaysPrivateWhileCommittedOriginBranchSurvivesRestriction`; `testExplicitBaselineSkipsHistoricalAuthorAndTransientUnmappedOwnerThenRestarts` |
| Interrupted intake does not admit other staged data; exact retries preserve histories | `PersonalSyncTests.testInterruptedIncomingPublicationAutomaticallyRecoversWithoutAdmittingAnotherStage`; `testLostOrMalformedCompletedCursorRescansWithoutDuplicateHistory` |
| Current membership excludes an omitted peer and does not delegate trust through item content | `PersonalSyncTests.testRemovalNeedsRetainedMembersOnlyAndOmittedPeerCannotUseOldCredentials` |
| Trusted administrator transitions retain identity mapping and receiver permission boundaries | `PersonalEnrollmentAuthorizationTests.testTrustedSourceDecisionMapsAliceWithoutReceiverLocalAdministratorVeto`; `PersonalEnrollmentAdmissionTests.testMissingAndAmbiguousMappingsFailWithoutChangingEitherPolicy` |

Two former tests were ported to current invariants rather than removed: `AtomicAuthorityActivationTests.testCurrentPersonalPolicyDoesNotAdmitServiceAccountBeforeOrAfterReopen` preserves service-account denial and admitted-human administration across cold reopen; `AtomicAuthorityProducerTests.testCurrentPersonalFreshAndJoiningReplicaNeedNoAuditGenesis` verifies fresh personal creation, a distinct joining replica and reopened ordinary history without an authority genesis ledger.

`AtomicAuthorityCompatibilityTests` continues to validate the retained floor-15 format transition. Its historical floor-14 fixture uses the retained atomic capability set, rather than importing newer floor-18 personal capabilities. Current floor-18 support and retained floor-15 support are checked separately; lock, custody, exact-prior, old-reader rejection and no-rewrite assertions are preserved.
