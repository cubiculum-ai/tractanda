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

## Native enrollment supervisor and operator remainder

The following exact14 methods used a current personal-store factory followed by the retired metadata approved-baseline flow and failed before their intended checks. Originals remain reachable at `b456e137eff5c2bba094c7f2c775b4c9bdda3e62`. Only these bodies are retired; independent SSH quoting/argv/custody and supervisor codec tests remain.

- `NativePeerEnrollmentSupervisorTests.testActualNativeSourceAndFixedHelperTransferRegisterAndExactRetry`
- `NativePeerEnrollmentSupervisorTests.testLostClosedAfterFinishedSkipsRegistrationThenExactRetryCompletes`
- `NativePeerEnrollmentSupervisorTests.testRepeatedExactTransientStopsOnCancellationDrainsChildAndNeverRegisters`
- `NativePeerEnrollmentSupervisorTests.testSimulatedSSHCancelledTransferReportsRemoteUncertaintyAndReapsOnlyLocalClient`
- `NativePeerEnrollmentSupervisorTests.testSimulatedSSHExit255AndOldReadyNeverSendPrivateInputOrRegister`
- `NativePeerEnrollmentSupervisorTests.testSimulatedSSHLostClosedAndExitAfterClosedSkipRegistrationUntilExactRetry`
- `NativePeerEnrollmentSupervisorTests.testSimulatedSSHQuotedCommandActualHelperTransferAndExactRetry`
- `NativePeerEnrollmentSupervisorTests.testWrongSourceKernelIdentityAndOldReadyRefuseBeforePrivateInput`
- `PeerEnrollmentOperatorTests.testAcceptedNativeAcknowledgmentAllowsExactHistoricalAuthorOrCurrentAdminOnly`
- `PeerEnrollmentOperatorTests.testReadOnlyStatusPreservesCanonicalAndPrivateJournalsAtEveryPhase`
- `PeerEnrollmentOperatorTests.testRealTargetOnlyOutputPreservesExactPrivateWitnessAndRejectsSourceOrientation`
- `PeerEnrollmentOperatorTests.testReducedAppendBudgetMeasuresTailProgressAcrossReopen`
- `PeerEnrollmentOperatorTests.testReducedFinishBudgetMeasuresProgressAcrossReopen`
- `PeerOperatorStatusTests.testPendingTargetDiagnosticCannotCreateActivationOrOpenOrdinaryService`

Current invariant mapping:

| Invariant | Current coverage |
| --- | --- |
| transfer | `PersonalEnrollmentDaemonTests.testTwoNodesPairOverSingleOutboundConnectionAndReplicateHistoryAndPayload`, `PersonalPeerDaemonTests.testActualDaemonPairFreshEnrollmentBidirectionalWriteAndRestart`, `PersonalSyncTests.testOriginalChunksResumeFromPhysicalPrefixAndStayUnreferencedUntilRevisionApply`, `PersonalRecoveryInventoryTests.testSavedDocumentClosureIsVerifiedWithoutPlacementIndexAndMissingPageIsDiagnosed` |
| retry | `PersonalEnrollmentTargetTests.testLostClaimReplyReopensExactContinuationWithoutLeakingStatus`, `PersonalEnrollmentTargetTests.testOnlyExactContinuationAcknowledgementConsumesInvitation`, `PersonalEnrollmentTargetTests.testAcceptedPlanPersistsBeforePolicyAdoptionAndResumesExactly`, `PersonalEnrollmentReplacementTests.testLostNewClaimReplyResumesSameCandidateContinuation` |
| cancel | `PersonalEnrollmentLifecycleTests.testRetainedRecoveryCancelsAndReapsBlockedRenewalWithoutCachedSession`, `PersonalEnrollmentLifecycleTests.testActualRetainedReplyWinsDuringRenewalCancellationDrain`, `PersonalEnrollmentRuntimeTests.testIssuerPushAndCancellationUseTheSingleTargetInitiatedContinuationSocket`, `PersonalEnrollmentDaemonTests.testDaemonCloseCancelsPrivateSessionWaitingForBody` |
| identity | `PersonalEnrollmentDaemonTests.testPrivateSessionPinsCanonicalNameAcrossReadyAndBody`, `NativePeerEnrollmentTests.testPrivateOutputReauthorizesCurrentPersonalAdminAfterAwait`, `PersonalEnrollmentTests.testLocalAuthorizationRequiresActualCurrentAdministrator` |
| ssh | `PeerEnrollmentSSHTests.testFixedHybridOnlyArgvAndBothManagedRemotePaths`, `PeerEnrollmentSSHTests.testStrictDestinationGrammarAndRemoteCustodyDoesNotResolveLocalAccounts`, `PeerEnrollmentSSHTests.testPOSIXQuotingPreservesPublicMetacharactersAndBoundsCompletedCommand`, `PeerEnrollmentSSHTests.testFixedTrustedLocalSSHLaunchAlwaysHasIndirectCustody`, `PeerEnrollmentSupervisorTests.testFixedImageSiblingRejectsLinksWritableHelperAndMutationACL` |
| read | `PersonalEnrollmentReplacementTests.testRepeatedRenewalProbeRotationAndPureReadsKeepOnlyOldContinuations`, `PersonalEnrollmentTargetTests.testLostClaimReplyReopensExactContinuationWithoutLeakingStatus`, `PersonalClusterStatusTests.testObservationBoundsAndRemoteErrorsCannotLeakTerminalContent` |
| secret | `PersonalEnrollmentTests.testPrivateInvitationRoundTripAndDiagnosticsRedactSecrets`, `PersonalEnrollmentJMAPTests.testStructuredClaimRoundTripAndOnlySecretIsCanonicalBase64`, `PersonalEnrollmentJMAPTests.testForeignAccountForgedPurposeUnknownFieldsAndUIDDoNotReachHandler`, `NativePeerEnrollmentTests.testBinaryTargetOutputUsesActualBoundAndListenerDrainsHeldOutputAndCancel` |
| fence | `PersonalEnrollmentJoiningTests.testFreshJoiningTargetAllowsIdentityAdminAndSelectionButDeniesNormalContent`, `PersonalEnrollmentJoiningTests.testUnjoinedFenceSurvivesEveryPreIdentityActivationBoundaryAndReopen`, `PersonalEnrollmentTargetTests.testUnacknowledgedClaimCannotAdoptSourcePlan`, `PersonalSyncTests.testPendingMembershipCannotServeDataAndNeedsEveryLiveAcknowledgement` |

`NativePeerEnrollmentSupervisorTests.testCurrentPersonalPrivateClientRefusesWrongKernelUIDAndUnsupportedReadyBeforeBody` replaces the uncovered current socket privacy boundary: the real `NativePersonalEnrollment.call` must send no BEGIN/body to a wrong kernel UID, and no private body after an unsupported READY. It uses owned local sockets/tasks and checks EOF, the actual current BEGIN byte count and exact refusal codes, with no authority store or helper. This change is pending native qualification; this document is not a passing test receipt.

Old demoted historical-author acknowledgement, retained approval-receipt prerequisites, helper CLOSED/SSH-reap registration and fixed proof-package read geometry are retired semantics. Current administrator checks, exact invitation/continuation recovery, private-status redaction, baseline gates, payload-prefix resume and cancellation/drain remain covered by the named current tests. Current pairing does not execute the retired SSH helper; independent exact public-command quoting checks are retained without claiming actual SSH/KEX or remote process lifecycle validation.

The retained `PeerEnrollmentSupervisorTests.testSourceChunkAndHelperReplyRejectShortOffsetDescriptorAndOldVersion` now constructs its exact chunk descriptor and bytes directly. Its offset, short-body, descriptor, helper-version, request-shape and error-reply checks remain, including an explicit mismatched-descriptor rejection. Only its subsequent obsolete `nativeEnrollmentCall(register)`/authority-registration receipt replay tail was retired under the same explicit review. Current exact continuation/publication retry and private client trust are covered by the current enrollment and socket cases mapped above; the original tail remains reachable in Git at `d520f9979f7b0d2887d8df48d6275ef0a77d910e`.

## Legacy scheduler/responder remainder and current ports

The following seven old bodies required metadata admission, authority genesis or legacy wire/lease semantics. Originals remain reachable at `50bea21b830b5f3d2acb4e86b2b59afe1dbcdc84`. The six Runtime/Scheduler bodies are retired; the responder method retains its name and its two-client, bidirectional and unpaired/wrong-key security checks while using the actual current Personal TCP transport. Independent helpers remain.

- `PeerResponderLoopbackTests.testTwoDistinctReplicasShareLoopbackResponderAndRejectUnpairedOrWrongKeyClients`
- `PeerSyncRuntimeTests.testCancelledOlderServerFactoryDoesNotDiscardReplacementContext`
- `PeerSyncRuntimeTests.testFiniteJobsReconnectAcrossMorePagesThanOneSocketAndQuiesceWithoutNewPackages`
- `PeerSyncRuntimeTests.testOverlappingTakeoverCannotInvalidateNewLeaseOrLoseUnacknowledgedPage`
- `PeerSyncRuntimeTests.testRealFailureAfterJobQuantumIsNotReportedAsYield`
- `PeerSyncSchedulerTests.testBoundedFairSchedulingReplacementAndDrainedClose`
- `PeerSyncSchedulerTests.testMissingOutcomeThenYieldResumesPromptlyWithoutBypassingRepair`

`PeerSyncSchedulerTests.testCurrentPersonalRuntimeBoundsHeldPullsDrainsCloseAndRejectsOldCompletion` uses four tiny current stores, legitimate current membership readiness/credential APIs and actual TCP current Personal connections. Existing completed-cut callbacks deliberately hold two current jobs while a third authenticated peer waits. An old held completion is released after a replacement session publishes its newer zero-revision report; that report/session and completed-cut count must remain intact. Shutdown must retain both held lifetime owners, await their release, drain to zero jobs and start no later work. No production seam, old .25-second scheduling policy, audit-package quantum or default healthy-operation deadline is added.

`PeerResponderLoopbackTests.testTwoDistinctReplicasShareLoopbackResponderAndRejectUnpairedOrWrongKeyClients` uses two distinct replica identities/PSKs on one actual current TCP responder. Both directions must exchange replies, unknown pairing ID and wrong PSK must fail before readiness with zero additional application calls, and both accepted valid clients must survive the rejected handshakes. This transport proof does not claim canonical store admission.

Current finite cuts/reconnect, physical payload-prefix resume, unchanged-row watermark, real failed-cut readiness, current revocation and late progress protections remain mapped to `PersonalPeerDaemonTests` actual-pair, compact-status and hot-enrollment cases; `PersonalSyncTests` finite-cut, original-prefix, lost-cursor and reply-after-removal cases; `PersonalPeerRoutingConnectionTests` cancellation and alias-race cases; and independent TLS wrong-secret tests. Qualification of these new ports is pending; old receipts are not aggregated into a final passing run.

## Historical runtime snapshot and target helper tail

The following exact11 observed failures are retired by the native snapshot owner; originals remain reachable at `4054bad4be1aa32aba50098c3090aae96df36673`. RuntimeSnapshot's other six methods and TargetEnrollment's two pure schema/pipe methods remain. Index rebuilding does not need to alter current personal membership, and ordinary content/recovery no longer requires old authority admission receipts.

- `PeerRuntimeSnapshotTests.testActivatedCredentialsLoadWhenServiceOwnerIsNotAdministrator`
- `PeerRuntimeSnapshotTests.testCanonicalAdmissionFencesSnapshotWithoutPairingConfigurationChange`
- `PeerRuntimeSnapshotTests.testRebuildFencesCapturedAndPreviouslyIssuedSnapshots`
- `PeerRuntimeSnapshotTests.testRotationWhileSnapshotDeliveryWaitsRejectsStaleRefresh`
- `PeerTargetEnrollmentTests.testActualBuiltHelperResumesPartialOriginalAndLostFinishReply`
- `PeerTargetEnrollmentTests.testHeldAppendCancellationKeepsWriterUntilSynchronousOwnerDrains`
- `PeerTargetEnrollmentTests.testMalformedHeadersWrongPinsAndAbsoluteDeadlineFailBeforeOpening`
- `PeerTargetEnrollmentTests.testOpeningCancellationRetainsWriterAndDrainsBeforeReturning`
- `PeerTargetEnrollmentTests.testPageAdvanceForgedSelectionAndWriterContentionStayClosed`
- `PeerTargetEnrollmentTests.testScopedControlRestoresAfterThrowCancellationAndRejectsNestedOwner`
- `PeerTargetEnrollmentTests.testStrongClosedReleasesWriterBeforeAcknowledgement`

Current replacement coverage (separate current contracts, no claim of old helper wire compatibility):

- `TractandaPeerTransportTests.CurrentPersonalTransportInvariantTests.testCurrentSuspendedReplyRechecksMembershipAndDisconnectNeverReturnsSuccess`
- `TractandaPeerTransportTests.CurrentPersonalTransportInvariantTests.testCurrentIncrementalHeadersOrderingAndUnsolicitedRepliesCloseTheActualHandler`
- `TractandaCoreTests.PersonalSyncTests.testReplyCapturedBeforeRemovalCannotAppendFinishOrApplyAfterCurrentMembershipChanges`
- `TractandaCoreTests.PersonalEnrollmentTargetTests.testAcceptedPlanPersistsBeforePolicyAdoptionAndResumesExactly`
- `TractandaCoreTests.PersonalEnrollmentTargetTests.testUnacknowledgedClaimCannotAdoptSourcePlan`
- `TractandaCoreTests.PersonalEnrollmentJoiningTests.testUnjoinedFenceSurvivesEveryPreIdentityActivationBoundaryAndReopen`
- `TractandaServerTests.PersonalEnrollmentDaemonTests.testDaemonCloseCancelsPrivateSessionWaitingForBody`
- `TractandaServerTests.NativePeerEnrollmentSupervisorTests.testCurrentPersonalPrivateClientRefusesWrongKernelUIDAndUnsupportedReadyBeforeBody`
- `TractandaCoreTests.PersonalSyncTests.testOriginalChunksResumeFromPhysicalPrefixAndStayUnreferencedUntilRevisionApply`

The current tests retain membership rechecks and private-output refusal, persisted plan/reopen, unacknowledged target fences, baseline readiness, cancellation/drain, partial payload privacy and exact retry. Current socket UID/READY, supervisor codec/custody and schema/pipe assertions remain independent. Native qualification is still required.

Current package adoption replaces the following three obsolete authority-era lifecycle bodies. Originals remain reachable at `d520f9979f7b0d2887d8df48d6275ef0a77d910e`.

- `SetupPackageLifecycleTests.testActivatedPreparedAdoptionValidatesRealAuthorityAndPreservesIdentityKeysAndPolicy` is ported to `testPersonalPreparedAdoptionPreservesIdentityProfileItemsKeysAndPolicyWithoutBootstrap`, checking actual current adoption with unchanged identities, profile, item permissions and pending credentials, and no authority bootstrap.
- `SetupPackageLifecycleTests.testPreparedAdoptionRejectsLostActivationProofWithoutRepairingIt` is ported to `testPersonalPreparedAdoptionRejectsDamagedCurrentProfileWithoutRepairOrBootstrap`, preserving refusal, no repair, no receipt and no bootstrap checks for a damaged current profile.
- `SetupPackageLifecycleTests.testPreparedAdoptionRejectsActualCanonicalTargetDisposalAndPreservesEvidence` required permanent historical disposal. Current omission and credential rejection are covered by `PersonalSyncTests.testRemovalNeedsRetainedMembersOnlyAndOmittedPeerCannotUseOldCredentials` and `testReplyCapturedBeforeRemovalCannotAppendFinishOrApplyAfterCurrentMembershipChanges`; explicit administrator-controlled readmission remains allowed.

Independent pending-target, mismatched-identity, custody, capture, rollback, no-bootstrap, no-account, no-data-loss and incompatible-manifest checks remain. Current rollback fixtures advance the real personal reader floor from16 to18 through personal-sync publication and retain rejection of the captured older reader.

`AuthorityCausalStoreTests.testUnseenOfflineWriteIsDemotedWithNewChangedViewRevisionAndExactReadableHistory` retains its historical admitted-get and demotion evidence, with the exact original bytes also checked through the production history DTO. Current public revision-by-ID history and current-permission protection are exercised independently by `JMAPNativeBoundaryTests.testPersonalRevisionGetKeepsImmutableHistoryAndAppliesCurrentItemACL`: two content revisions remain readable before restriction, all historical IDs are undisclosed to the restricted caller afterward, and the owner still reads the exact immutable originals.
