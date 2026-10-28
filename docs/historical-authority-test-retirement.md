# Historical authority integration tests

The current fresh-store factory creates the personal/workgroup profile. Its peer access follows current membership and credentials; ordinary item history and recovery do not depend on atomic acceptance receipts, permanent retirement histories or an authorization ledger. Calling the retained metadata-audit intake configuration, enrollment, credential rotation or retirement APIs on that profile must return `peerIntakeDisabled` without changing any store files or modes. `RetiredAuthorityEntryPointTests` checks those four refused operations against actual current stores and retained item histories.

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

## Retired metadata-runtime integration bodies

A further 30 precisely enumerated failing integration methods used the retired canonical authority genesis, metadata enrollment and old exchange handler. Their originals remain in the same reachable `d520f9979f7b0d2887d8df48d6275ef0a77d910e` source. Passing codec, private-frame fragmentation, listener cancellation, raw protocol-negative and current personal tests remain active; no target or class exclusion was added.

### NativeCredentialRegistrationTests

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaServerTests/NativeCredentialRegistrationTests.swift)

- `testKernelServiceOwnerIsDeniedBeforePayloadAndGenericRoutesHaveNoAdapter`
- `testKernelSocketRegistrationAndExactCurrentRetryUseExistingImmutableBytes`
- `testReadyIsNotAuthorityAndContextCancellationAndShutdownFailClosed`

### PeerExchangeTests

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaPeerTransportTests/PeerExchangeTests.swift)

- `testAuthenticatedBidirectionalOriginalExchangeSurvivesOrdinaryWriteAndResume`
- `testCommitCompletionWaitOutlivesOrdinaryOperationDeadline`
- `testCompatibilityFinalFreshnessRejectsFloorAdvanceAndCancellationBeforeReady`
- `testCompatibilityOldMissingAndOutOfOrderReadyCannotReachOrdinaryExchange`
- `testCompatibilityReadyWaitsForBothSidesAndCoalescedFirstRequestSurvivesAsymmetricDelay`
- `testDelayedReceivedResponseReauthorizesBeforeCallerSuccess`
- `testDelayedServerResultReauthorizesBeforeReturningUserData`
- `testDisconnectCancelsPausedResponseAuthorizationWithoutCallerSuccess`
- `testDuplicateUnorderedUnsolicitedAndPipelinedFramesAreRejected`
- `testEncryptedDocumentPartsResumeAtChunkBoundaryAndRelayExactSavedOutcomes`
- `testEncryptedOriginalStreamsInBoundedFramesAndPublishesBeforeReference`
- `testExistingSessionCannotInitiateRequestToRetiredActualRemote`
- `testExistingSessionReturnsOnlySanitizedRemoteRetirementDenial`
- `testFragmentedAndCoalescedInvalidPrefixesCloseAtHeaderBoundary`
- `testMissingParentRequiresLaterExactTransferAndExplicitCommitRetry`
- `testPersistedCurrentPairingsAuthenticateExchangeAfterServiceRestart`
- `testRequestQuotaAndAbsoluteSessionDeadlineRejectFurtherWork`
- `testRetainedPairingCannotOpenAfterActualRemoteRetirement`
- `testSharedResponderRetainedCredentialCannotOpenAfterActualRemoteRetirement`
- `testSharedResponderRetainedCredentialCannotOpenAfterRotation`

### PeerServiceRuntimeTests

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaServerTests/PeerServiceRuntimeTests.swift)

- `testActivatedPeerFallbackBidirectionalExchangeOrdinaryWriteAndShutdown`
- `testCancelledConnectorRetainsSharedDNSBudgetAndCloseDrainsActualLookup`
- `testRebuildRecoversFreshSnapshotAndStaleRefreshCannotRepublishAfterStop`
- `testUnknownWrongSecretRotationAndDisposalDenyCurrentAdmission`

### PeerSyncMeshTests

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaServerTests/PeerSyncMeshTests.swift)

- `testThreeNodesCycleOfflineConcurrentMetadataWritersAndColdIndexRecoveryQuiesce`
- `testThreeNodesRelayResumeAndMergeSavedDocumentReferencesThenRebuildQuiescently`

### SharedDaemonTests

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaServerTests/SharedDaemonTests.swift)

- `testSharedDaemonActivatedPeersOwnListenerConnectorAndChildren`

### Current transport and storage coverage

- `CurrentPersonalTransportInvariantTests.testCurrentIncrementalHeadersOrderingAndUnsolicitedRepliesCloseTheActualHandler` exercises fragmented invalid headers, ordering, duplicate/pipelined requests and unsolicited replies on real protected current frames.
- `testCurrentSuspendedReplyRechecksMembershipAndDisconnectNeverReturnsSuccess` suspends a current operation, then revokes its binding or disconnects before reply delivery.
- `testDefaultHealthyWaitSurvivesVirtualDaysAndOnlyExplicitLimitExpiresIt` proves the selected healthy-wait policy and explicit opt-in operation limits. Old absolute session lifetime and cumulative session quotas are not current requirements.
- `PersonalSyncTests.testReplyCapturedBeforeRemovalCannotAppendFinishOrApplyAfterCurrentMembershipChanges` verifies the actual current Core admission boundary. Receiving bytes through an internal transport promise is not canonical acceptance.
- `CurrentPublicationWaitTests.testCancelledWaitAfterDurablePublicationFinishesAndExactRetryRevealsOneRevision` cancels at the real durable acknowledgement hook, then proves one immutable revision and the same operation's exact retry outcome after reopen.
- Existing `PersonalPeerConnectionTests`, `PersonalPeerRoutingConnectionTests`, `PeerNameResolverTests`, `PersonalPeerJMAPTests` and `PersonalEnrollmentJMAPTests` retain actual TLS duplex, purpose/correlation, DNS/TLS cancellation, allocation bounds, private mutations and exact-retry checks.
- `PersonalPeerDaemonTests.testActualDaemonPairFreshEnrollmentBidirectionalWriteAndRestart` covers current daemon data and owned payloads; its hot-enrollment bridge test closes a revoked live data session. Current nonfounder three-node enrollment/direct edits, DAG/rebuild and saved-document recovery remain in the personal enrollment, sync, DAG and store suites.
- The ported `SharedDaemonTests` keep explicit current runtime documents, empty-listener refusal, startup unwind, physical store identity and closure/port-release assertions. Current private registration framing and listener-close cancellation tests remain in `NativeCredentialRegistrationTests` and `PersonalEnrollmentDaemonTests`.

The five new grouped invariants passed within the single composed macOS invocation recorded at commit `cf1f2765c52400f7b0de6133466821c44708dc7b` (83 tests, zero failures/skips). That receipt is a bounded qualification, not a full-suite or deployment claim.

## Metadata enrollment/admission diagnostic reconciliation

The targeted diagnostic at commit `7b43a9993186eb8b93f63b51620a24d8721a839a` executed all 64 methods in the old approval, activation and origin-admission suites: 2 passed, 61 methods failed, and one pre-existing isolated-root case was skipped. XCTest counted 62 failed assertions (61 unexpected). The following exact 61 failed method bodies were retired; no additional target/file exclusion or new skip was introduced. The two passing historical held-data/negative cases and the pre-existing privileged-custody case remain unchanged.

These methods required the retired canonical approval/admission/retirement protocol. Its retrospective receipt reconsideration, transitive issuer depth and permanent bootstrap proofs do not determine current membership. The explicit captured-policy case also exercised that retired trust protocol; it was not an ordinary retained item-format reader test. Production validation was not loosened to accept its old authority-record shapes.

### PeerEnrollmentActivationTests

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaCoreTests/PeerEnrollmentActivationTests.swift)

- `testAcceptedBaselineCrashBeforeActivationConfigurationResumesOnlyPrivateOwner`
- `testActualPreparedTargetActivatesRegistersReopensAndRebuilds`
- `testCompletedCanonicalTargetCopiesToNewDirectoryWithExactIdentityKeysAndReceipt`
- `testDistinctCurrentGlobalAdministratorCompletesOnlyTheAcceptedOperation`
- `testEstablishedTargetIdentityCannotBeRegeneratedOrSubstituted`
- `testIncompleteAttachmentPayloadKeepsTargetClosedUntilExactOriginalArrives`
- `testIndependentApprovalPinAndSourceIdentitySubstitutionFailBeforeIdentity`
- `testInterruptedConfigurationCommitIsExactRecoverableCompletion`
- `testLostPreparationAndRequestKeepWarmAndColdOpeningClosed`
- `testLostWholeActivationDirectoryAndPreparationKeepWarmAndColdOpeningClosed`
- `testMissingCanonicalApprovalSealFailsColdRecovery`
- `testMissingPreparationDoesNotTurnActivatedTargetIntoOrdinaryUnsealedStore`
- `testOriginalAuthorCompletionRejectsNumericUIDRemappedToAnotherName`
- `testPendingAndInterruptedPinKeepOrdinaryOpeningClosed`
- `testPreparedTargetCannotExposeUnattendedRuntimeCredentialsBeforeActivation`
- `testSourceDisposedOrRevokedPairingCannotBeReadmittedByAcceptedOperation`
- `testSourceRegistrationHistoricalCompletionSurvivesAuthorDemotionButDoesNotAuthorizeNewExport`
- `testSourceRegistrationInterruptedAfterCommitRetainsExactBaseline`
- `testSourceRegistrationRequiresOriginalFullPrivateBytes`
- `testTargetLaterDisposesSourceWithoutErasingHistoricalActivation`
- `testTargetRotationPreservesActivationAndMembershipWithoutOriginalSecret`
- `testTargetSecretChangedRetryAndMissingEstablishedSecretFailClosed`
- `testUnrelatedConfigurationChangeStillFencesRegisteredBaselineAndCompletion`
- `testUnsafeActivationArtifactPresenceCannotRemoveGate`
- `testWarmCheckpointActivationValidationSkipsUserBaselineTraversalButExplicitRebuildReadsIt`
- `testWrongManifestAndUnlistedObjectCannotExpandFiniteIntake`

### PeerEnrollmentApprovalTests

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaCoreTests/PeerEnrollmentApprovalTests.swift)

- `testAcceptedApprovalCannotBypassCredentialRevocationOrTargetDisposal`
- `testAcceptedSealedBaselineSurvivesCanonicalOnlyIndexRebuild`
- `testExactRetryPreservesIdentitiesAndRejectsDifferentSecretOrPreparation`
- `testFiniteBaselineExcludesConcurrentLaterWritesAndRetainsPermanentBootstrap`
- `testMissingOrChangedPrivateKeyCannotBeRecreatedByRetryOrRead`
- `testPolicyChangeFencesUnacceptedOperation`
- `testPrivateAcceptedMarkerCannotAuthorizeUnsealedApproval`
- `testPrivateStagingNeverConfiguresOrAuthenticatesUnapprovedPeer`
- `testReplacingBothKeysWithSameNewSecretCannotChangePrivateOperationWitness`
- `testRevokedAdministratorBeforeSealNeverAcceptsButAcceptedBookkeepingSurvivesDemotion`
- `testTamperedCanonicalApprovalSealCannotCompleteOrReplay`
- `testUnfinishedEpochLossNeedsReviewAndDoesNotBlockOrdinaryService`

### PeerOriginAdmissionTests

[Original source](https://github.com/cubiculum-ai/tractanda/blob/d520f9979f7b0d2887d8df48d6275ef0a77d910e/Tests/TractandaCoreTests/PeerOriginAdmissionTests.swift)

- `testAcceptedExplicitTargetPreservesSealedBaselineAndExactKeys`
- `testAdmissionFrontierFencesOldInventoryCompletionWithoutInvalidatingOwnBaseline`
- `testAdmissionRequiresBoundedCanonicalReads`
- `testAncestorChannelRevocationAndLaterDisposalPreserveEarlierDescendantMembership`
- `testAnchoredNonRootDecisionAndRealAuthoredRelayExportSurviveCanonicalRebuild`
- `testCanonicalApprovalPublicationMetadataSharesTheActualReadBudget`
- `testDerivedReceiptAdmissionPreservesHeldRejectedAndQueuesOnlyUnknown`
- `testEarlierUnanchoredNonRootDecisionStaysInertAfterIssuerAdmission`
- `testFreshFactoryPublicPolicyBaselineSupportsRealNonRootAuthorityAndRebuild`
- `testFullDirtyAndMissingIndexRecoveryStillReadOriginalsAndPreserveMembership`
- `testInterruptedRemoteAdmissionReplaysCanonicalProofAndDuplicateIsIdempotent`
- `testMissingAdmittedOriginProofCannotBeResealedByWarmOrColdReplay`
- `testMissingPublicPublicationCannotBeReplacedByPrivateAcceptedMarker`
- `testMissingRetainedPackageSealFailsBeforeConfiguredOriginOrLocalSkip`
- `testNonRootWrongMissingIssuerAndForgedHistoricalAdministratorNeverAdmit`
- `testOnlyCanonicalExplicitTargetIsAdmittedAndTamperedIssuerFailsClosed`
- `testOriginReplayProjectionRejectsMalformedOrMissingVerifiedMetadata`
- `testOwnAdmissionExceptionDoesNotPermitUnrelatedConfigurationChange`
- `testPublicMembershipRebuildDoesNotRequireOriginalPrivateSecret`
- `testRavenAdmissionReconsidersStarletReceiptAtStashWithoutRePairing`
- `testSelfTrustAndConfiguredDepthLimitFailClosed`
- `testUnrelatedAdmissionFencesPreviouslyAcceptedSourceBaseline`
- `testWarmOriginReplayUsesTypedMetadataWithoutReadingTwoLargeUserOriginals`

### Retained current enrollment invariants

The current equivalents use real current APIs and retain their security/storage assertions:

| Invariant | Current coverage |
| --- | --- |
| Private invitation, single claim, exact continuation retry, no secret disclosure and mode/hardlink custody | `PersonalEnrollmentTests` invitation/claim/custody methods; `PersonalEnrollmentReplacementTests` lost-claim, malformed/foreign-candidate and publication-recovery methods |
| Target identity/readiness fences and no ordinary content before joining activation | `PersonalEnrollmentJoiningTests.testUnjoinedFenceSurvivesEveryPreIdentityActivationBoundaryAndReopen`, `testFreshJoiningTargetAllowsIdentityAdminAndSelectionButDeniesNormalContent`, `testReadinessRequiresSameSelectionProcessJobAndSourceGeneration`; current completion requires exact persisted membership |
| Current administrator authorization and cross-host logical UID/group mapping | `PersonalEnrollmentAuthorizationTests` source-decision, exact sender/digest/operation and administrator recheck methods; `PersonalEnrollmentAdmissionTests` name mapping, missing/ambiguous mappings and policy drift methods |
| Finite baseline, bounded owned payload transfer, no collision overwrite and no implicit staged-data promotion | `PersonalSyncTests.testFiniteCutUsesLocalRowsWithConcurrentBackdatedUUIDAndRebuildRescan`, `testRawRoundTripIsKnownAcrossRoutesAndCollisionNeverOverwrites`, `testInterruptedIncomingPublicationAutomaticallyRecoversWithoutAdmittingAnotherStage`, `testOriginalChunksResumeFromPhysicalPrefixAndStayUnreferencedUntilRevisionApply` |
| Warm compatible opening, canonical history/index recovery and current ACLs across all history | `PersonalWorkgroupStoreTests.testCompatibleUpgradeUsesEstablishedFenceWithoutInventoryAndStartupStillChecksContent`, `testAcknowledgedOwnedContentSurvivesAbruptProcessExitAndDisposableIndexLoss`, `testSelectedMergeHistoryOwnedDocumentAndOldPolicyItemRemainOrdinaryContent`, `testCurrentACLRevocationAndLocalPolicySurviveRebuild` |
| Current node exclusion, authenticated native join/restart, one initiated duplex connection and nonfounder third-node coordination | `PersonalSyncTests.testRemovalNeedsRetainedMembersOnlyAndOmittedPeerCannotUseOldCredentials`; `PersonalPeerDaemonTests` actual pair/hot-revocation cases; `PersonalEnrollmentDaemonTests.testTwoNodesPairOverSingleOutboundConnectionAndReplicateHistoryAndPayload` and `testNonFounderAddsThirdNodeOnlyAfterRetainedMemberReturns` |

Current membership and credentials are administrator-controlled operational configuration. Index-only recovery preserves that current configuration; fresh-cluster recovery explicitly pairs new credentials. Recovered raw items or old policy/authority items cannot recreate current trust. The rejected historical ledger is not repaired or required to certify an administrator-selected recovery set.

## Explicit historical maintenance and metadata-control tail cases

The following eight observed failures exercise superseded authority-store opening, admission, or conversion/export success. Their originals remain reachable at `d520f9979f7b0d2887d8df48d6275ef0a77d910e`. No current production initialization guard is relaxed. Independent maintenance fence, canonical-writer, accepted-proof, unknown-scratch and no-write tests remain.

- `Tests/TractandaCoreTests/CanonicalMaintenanceContextTests.swift::testRealMaintenanceStorePreservesReadsButRejectsOrdinaryCommit`
- `Tests/TractandaCoreTests/CanonicalMaintenanceContextTests.swift::testRealColdRebuildKeepsCanonicalDataOrStopsAtExactProposedOutput`
- `Tests/TractandaCoreTests/CanonicalMaintenanceContextTests.swift::testAdmissionCapabilityPrefaceIsFencedAndRealStoreStopsBeforeCanonicalWrite`
- `Tests/TractandaCoreTests/CanonicalMaintenanceContextTests.swift::testHistoricalAtomicColdRebuildUsesOnlyDerivedReaderScratchAndPreservesCanonicalBytes`
- `Tests/TractandaCoreTests/CanonicalMaintenanceContextTests.swift::testHistoricalArchiveBudgetRefusesActualRootWriteBeforeBytesAndRecordsFailure`
- `Tests/TractandaCoreTests/GlobalAdministratorScopeTests.swift::testForeignProtectedReviewUsesSourceDecisionAndPreservesCurrentACL`
- `Tests/TractandaCoreTests/GlobalAdministratorScopeTests.swift::testSourceValidatedRetirementAppliesWithoutRecipientAdministratorLookup`
- `scripts/development/first-source-conversion/DevelopmentFirstSourceConversionTests.swift::testSameOriginModernConversionExportsCompleteApprovedBaseline`

A new `CanonicalMaintenanceContextTests.testHistoricalMaintenancePlanCannotBypassExplicitPersonalActivationOrChangeCanonicalBytes` checks both retained historical formats, exact canonical byte preservation, and refusal without explicit personal activation. Current trusted source administration is covered by `PersonalEnrollmentAuthorizationTests`' mapping-without-local-veto, substitution rejection and source-admin recheck cases. Explicit selected-content recovery and unchanged files/history are covered by `PersonalWorkgroupStoreTests.testNormalOpenRequiresExplicitSelectionAndSelectedDAGPreservesFiles` and `testSelectedMergeHistoryOwnedDocumentAndOldPolicyItemRemainOrdinaryContent`. Historical conversion custody, identity and byte tests other than the single enumerated export tail remain.
