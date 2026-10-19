#!/usr/bin/env python3
"""Reviewed native Stash gate. Import and tiny tests never contact or mutate Stash."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import platform
import re
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import threading
import time
import uuid

SPEC = importlib.util.spec_from_file_location('cluster_gate', Path(__file__).with_name('verify-cluster-linux.py'))
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
REPO = Path(__file__).resolve().parents[1]
HOST = 'rcfa@stash.pirate-mora.ts.net'
SSH = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10',
       '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2', HOST]
CAP, ALLOWANCE, RESERVE, PREFLIGHT = 4 * 1024**3, 256 * 1024**2, 10 * 1024**3, 12 * 1024**3
SOURCE_CAP, FIXTURE_CAP, RESULT_CAP = 128 * 1024**2, 128 * 1024**2, 64 * 1024**2
DEFAULT_TIMEOUT_SECONDS = 24 * 60 * 60
MAX_TIMEOUT_SECONDS = 7 * 24 * 60 * 60
MIN_CLEANUP_HEADROOM_SECONDS = 120
MAX_CLEANUP_HEADROOM_SECONDS = 60 * 60
COLD_OUTPUT_ESTIMATE = 13 * 1024**3 // 4
PACKAGE_OUTPUT_ESTIMATE = 1024**3  # Within the unchanged aggregate 3.25GiB estimate.
LEASE_SECONDS = 15
REMOTE_UID, REMOTE_GID = 1001, 1001
REMOTE_HOME_PROBE = "import json,os,pwd; account=pwd.getpwuid(os.getuid()); print(json.dumps({'uid':os.getuid(),'gid':os.getgid(),'home':account.pw_dir}))"


def validated_remote_home(value):
    if (not isinstance(value, dict) or set(value) != {'uid', 'gid', 'home'}
            or type(value['uid']) is not int or value['uid'] != REMOTE_UID
            or type(value['gid']) is not int or value['gid'] != REMOTE_GID
            or not isinstance(value['home'], str)):
        raise RuntimeError('unexpected remote account/home identity')
    home = PurePosixPath(value['home'])
    if not home.is_absolute() or home == PurePosixPath('/') or '..' in home.parts or str(home) != value['home']:
        raise RuntimeError('remote account home is not a normalized absolute path')
    return Path(str(home))


def resolve_remote_home():
    output = subprocess.check_output(
        ssh_command(['python3', '-I', '-B', '-c', REMOTE_HOME_PROBE]), timeout=30)
    try:
        value = json.loads(output)
    except (TypeError, ValueError) as error:
        raise RuntimeError('remote account-home probe returned invalid JSON') from error
    return validated_remote_home(value)


def positive_timeout_seconds(value):
    try:
        seconds = int(value)
    except (TypeError, ValueError) as error:
        raise argparse.ArgumentTypeError('timeout must be a finite positive integer number of seconds') from error
    if seconds <= 0 or seconds > MAX_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError(f'timeout must be between 1 and {MAX_TIMEOUT_SECONDS} seconds')
    return seconds


def cleanup_headroom(timeout_seconds):
    return max(MIN_CLEANUP_HEADROOM_SECONDS,
               min(MAX_CLEANUP_HEADROOM_SECONDS, timeout_seconds // 100))


def timeout_budgets(timeout_seconds):
    if not 1 <= timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValueError('operation timeout is invalid')
    unit_cleanup = cleanup_headroom(timeout_seconds)
    unit_runtime = timeout_seconds + unit_cleanup
    ssh_cleanup = cleanup_headroom(unit_runtime)
    return {'operationSeconds': timeout_seconds, 'unitCleanupHeadroomSeconds': unit_cleanup,
            'unitRuntimeSeconds': unit_runtime, 'sshCleanupHeadroomSeconds': ssh_cleanup,
            'sshOwnerSeconds': unit_runtime + ssh_cleanup}


def effective_command_timeout(timeout_seconds, command_timeout_seconds):
    if not 1 <= timeout_seconds <= MAX_TIMEOUT_SECONDS or not 1 <= command_timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValueError('operation/command timeout is invalid')
    return min(timeout_seconds, command_timeout_seconds)
SUPPORT = ['verify-stash-cluster.py', 'verify-cluster-linux.py', 'verify-peer-transport.py']
# Existing guarded fixture sources; module names bind normalized Class.test selectors.
FIXTURE_SOURCES = {
    'SharedDaemonTests': ('TractandaServerTests', 't'),
    'DocumentJobCoordinatorTests': ('TractandaCoreTests', 'j'),
    'DocumentJobIntegrationTests': ('TractandaMCPTests', 'm'),
    'PeerSyncCoreTests': ('TractandaCoreTests', 'c'),
    'PeerVerificationParkingTests': ('TractandaCoreTests', 'p'),
    'PeerDocumentInspectionTests': ('TractandaCoreTests', 'i'),
    'PeerResponderLoopbackTests': ('TractandaPeerTransportTests', 'l'),
    'PeerServiceRuntimeTests': ('TractandaServerTests', 'r'),
    'PeerSyncRuntimeTests': ('TractandaServerTests', 's'),
    'PeerSyncMeshTests': ('TractandaServerTests', 'h'),
    'PeerSyncSchedulerTests': ('TractandaServerTests', 'q'),
    'PeerRuntimeConfigurationTests': ('TractandaServerTests', 'f'),
    'PeerOperatorStatusTests': ('TractandaCoreTests', 'o'),
    'PeerOperatorStatusNativeTests': ('TractandaServerTests', 'o'),
    'DevelopmentFirstSourceFixtureTests': ('FirstSourceConversionTests', 'd'),
    'PeerPrivateCredentialInputTests': ('TractandaCoreTests', 'v'),
    'NativeCredentialRegistrationTests': ('TractandaServerTests', 'v'),
    'PeerEnrollmentArtifactTests': ('TractandaCoreTests', 'e'),
    'PeerEnrollmentOperatorTests': ('TractandaCoreTests', 'e'),
    'NativePeerEnrollmentTests': ('TractandaServerTests', 'e'),
    'PeerTargetPreparationTests': ('TractandaSetupTests', 'e'),
    'SetupTests': ('TractandaSetupTests', 'u'), 'SetupPeerRuntimeTests': ('TractandaSetupTests', 'u'),
    'SetupLinuxPayloadTests': ('TractandaSetupTests', 'linux-setup'),
    'SetupPackageLifecycleTests': ('TractandaSetupTests', 'pkg'),
    'PeerTargetEnrollmentTests': ('TractandaCoreTests', 'e'),
    'PeerExchangeBoundaryTests': ('TractandaCoreTests', 'c'),
    'PeerExchangeCommitTests': ('TractandaCoreTests', 'c'),
    'PeerExchangeTests': ('TractandaPeerTransportTests', 'l'),
    'PeerEnrollmentSupervisorTests': ('TractandaCoreTests', 'e'),
    'NativePeerEnrollmentSupervisorTests': ('TractandaServerTests', 'e'),
}
PORTABLE_PATHS = {
    'Sources/TractandaCore/PageCorpusAllocation.swift',
    'Sources/TractandaCore/PageCorpusProjection.swift',
    'Tests/TractandaCoreTests/PageCorpusAllocationTests.swift',
}
CREDENTIAL_MODIFIED = {
    'Sources/TractandaCore/AuthorityStore.swift',
    'Sources/TractandaCore/PeerIntakeCoordinator.swift',
    'Sources/TractandaCore/ServiceCoordinator.swift',
    'Sources/TractandaCore/Store.swift',
    'Sources/TractandaPeerTransport/PeerPairing.swift',
    'Tests/TractandaCoreTests/PeerLifecycleStoreTests.swift',
    'Tests/TractandaPeerTransportTests/PeerExchangeTests.swift',
}
CREDENTIAL_ADDED = {
    'Sources/TractandaCore/PeerCredentialStore.swift',
    'Tests/TractandaCoreTests/PeerCredentialStoreTests.swift',
}


ENROLLMENT_MODIFIED = {'Sources/TractandaCore/Store.swift', 'Sources/TractandaCore/DocumentContentFiles.swift'}
ENROLLMENT_ADDED = {'Sources/TractandaCore/PeerEnrollment.swift', 'Tests/TractandaCoreTests/PeerEnrollmentTests.swift'}
ENROLLMENT_REGRESSIONS = {
    'TractandaCoreTests.DocumentContentStorageTests.testPublicationRetryUsesRetainedCandidateWithoutRegeneratingPages',
    'TractandaCoreTests.DocumentContentStorageTests.testRenameBeforeSynchronizationRetryMustRepairBothParents',
    'TractandaCoreTests.DocumentContentStorageTests.testSharedQuotaChargesProofNodesAndRetainedPartialDocumentAfterRestart',
    'TractandaCoreTests.DocumentContentStorageTests.testIndependentCopyCorruptionAndMissingDependencyFailClosed',
    'TractandaCoreTests.DocumentContentIntegrationTests.testCopyReceiptsSurviveActualStoreRestart',
    'TractandaCoreTests.ExternalIndexDirectoryTests.testCanonicalIdentityIsCreatedForDefaultIndexAndRejectsUnsafeIdentityFiles',
    'TractandaCoreTests.ExternalIndexDirectoryTests.testExternalDirectoryKeepsCanonicalHistoryAndConfigurationWhenRecreated',
    'TractandaCoreTests.PeerCredentialStoreTests.testPersistenceExactRetryRestartAndNoExportOrReflectionLeak',
    'TractandaCoreTests.PeerCredentialStoreTests.testMissingMalformedOversizedAndUnsafeFilesFailClosed',
}

FRESH_ADDED = {
    'Sources/TractandaCore/FreshStoreLifecycle.swift',
    'Sources/TractandaCore/InitialAuthorityBootstrap.swift',
    'Tests/TractandaCLITests/FreshStoreCommandTests.swift',
    'Tests/TractandaCoreTests/ClusterCanonicalRestoreTests.swift',
    'Tests/TractandaCoreTests/FreshStoreLifecycleTests.swift',
    'Tests/TractandaCoreTests/InitialAuthorityBootstrapTests.swift',
}
DEVELOPMENT_SWIFT = {
    'scripts/development/first-source-conversion/DevelopmentFirstSourceConversion.swift',
    'scripts/development/first-source-conversion/DevelopmentFirstSourceConversionTests.swift',
}
DEVELOPMENT_ANCILLARY = {
    'scripts/development/first-source-conversion/README.md',
    'scripts/development/first-source-conversion/run.py',
}


def checked_label(label):
    if not re.fullmatch(r'stash-cluster-b2-20261016-[0-9a-f]{8}', label):
        raise RuntimeError('invalid unique Stash run label')
    return label


def remote_root(home, label):
    home = Path(home)
    if (not home.is_absolute() or '..' in home.parts
            or str(PurePosixPath(str(home))) != str(home)):
        raise RuntimeError('remote account home path is unsafe')
    return home / '.cache' / ('tractanda-' + checked_label(label))


def safe_member(name):
    p = PurePosixPath(name)
    if p.is_absolute() or not p.parts or '..' in p.parts or str(p) != name or '\\' in name:
        raise RuntimeError('unsafe archive member: ' + name)
    return p


def safe_target(root, name):
    relative = safe_member(name)
    p = root
    for part in relative.parts:
        p = p / part
        if p.is_symlink():
            raise RuntimeError('symlink in frozen path: ' + name)
    return p


def local_space(path):
    fs = os.statvfs(path)
    available = fs.f_bavail * fs.f_frsize
    if fs.f_frsize <= 0 or fs.f_bavail < 0 or available - RESULT_CAP - 16 * 1024**2 < RESERVE:
        raise RuntimeError('local streamed-evidence reserve rejected')
    return dict(location=str(path), available=available, maximumEstimatedWrites=RESULT_CAP + 16 * 1024**2, reserve=RESERVE)


def capacity(root, fixtures=None, initial=False):
    fs = os.statvfs(root)
    if fs.f_frsize <= 0 or fs.f_bavail < 0:
        raise RuntimeError('genuine filesystem capacity unavailable')
    sample = dict(available=fs.f_bavail * fs.f_frsize, allocated=C.GATE.allocated_tree(root),
                  cap=CAP, runtimeAllowance=ALLOWANCE, reserve=RESERVE)
    sample['fixtureAllocated'] = C.GATE.allocated_tree(fixtures) if fixtures and fixtures.exists() else 0
    if sample['available'] < (PREFLIGHT if initial else RESERVE) or sample['allocated'] + ALLOWANCE > CAP or sample['fixtureAllocated'] > FIXTURE_CAP:
        raise RuntimeError('resource guard rejected: ' + json.dumps(sample))
    return sample


def admit_cold_work(sample, output_estimate=COLD_OUTPUT_ESTIMATE):
    additional = output_estimate + RESULT_CAP + FIXTURE_CAP
    final_estimate = sample['allocated'] + additional
    if sample['available'] < PREFLIGHT or sample['available'] - additional < RESERVE or final_estimate + ALLOWANCE > CAP:
        raise RuntimeError('cold-work preestimate rejected')
    return dict(initial=sample, additionalEstimatedBytes=additional, finalAllocatedEstimate=final_estimate,
                runtimeAllowance=ALLOWANCE, cap=CAP, reserve=RESERVE)


def verify_files(root, records, exact=False):
    expected = set()
    for row in records:
        safe_member(row['path'])
        p = safe_target(root, row['path'])
        if p.is_symlink() or not p.is_file() or p.stat().st_size != row['bytes'] or C.sha(p) != row['sha256']:
            raise RuntimeError('frozen input drift: ' + row['path'])
        expected.add(row['path'])
    if len(expected) != len(records):
        raise RuntimeError('duplicate frozen input')
    if exact:
        actual = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}
        if actual != expected:
            raise RuntimeError('frozen input inventory differs')


def checked_reference(reference):
    p = safe_target(REPO, reference['path'])
    if not p.is_file() or p.stat().st_size != reference['bytes'] or C.sha(p) != reference['sha256']:
        raise RuntimeError('verification reference changed: ' + reference['path'])
    return p


def validate_delta(before, after, changes):
    if set(before) != set(after):
        raise RuntimeError('portable delta changed source inventory')
    changed = {p for p in before if before[p] != after[p]}
    if changed != PORTABLE_PATHS or set(changes) != PORTABLE_PATHS:
        raise RuntimeError('portable delta must declare exactly the approved three paths')
    if any(changes[p] != dict(beforeSHA256=before[p], afterSHA256=after[p]) for p in changed):
        raise RuntimeError('portable delta hash binding differs')


def verify_mac_cases(status, output, ids, multiple_bundles=False):
    if status.get('running') is not False or status.get('exit') != 0:
        raise RuntimeError('focused Mac checkpoint did not complete successfully')
    found = []
    for name, outcome in re.findall(r"Test Case '([^']+)' (passed|failed|skipped)", output):
        if name.startswith('-[') and name.endswith(']'):
            name = name[2:-1].replace(' ', '.')
        if outcome != 'passed':
            raise RuntimeError('focused Mac checkpoint contains failure or skip')
        found.append(name)
    summaries = [tuple(map(int, v)) for v in re.findall(r'Executed (\d+) tests?, with (\d+) failures?', output)]
    if multiple_bundles:
        selected = [tuple(map(int,v)) for v in re.findall(r"Test Suite 'Selected tests' passed[^\n]*\n\s*Executed (\d+) tests?, with (\d+) failures?", output)]
        counts = {}
        for case in ids:
            module = case.split('.',1)[0]
            counts[module] = counts.get(module,0)+1
        summary_ok = (sum(v[0] for v in selected) == len(ids)
                      and sorted(v[0] for v in selected if v[0]) == sorted(counts.values())
                      and all(v[1] == 0 for v in selected))
    else:
        summary_ok = (len(ids), 0) in summaries
    if sorted(found) != sorted(ids) or len(set(found)) != len(ids) or not summary_ok or any(v[1] for v in summaries):
        raise RuntimeError('focused Mac checkpoint case set differs')


def source_basis(checkpoint):
    baseline = C.checked_json(REPO / C.MAC_SOURCE, C.MAC_SOURCE_SHA)['files']
    if checkpoint is None:
        return baseline, dict(kind='original1160', manifestSHA256=C.MAC_SOURCE_SHA), []
    if checkpoint.is_symlink() or not checkpoint.resolve().is_relative_to(REPO):
        raise RuntimeError('checkpoint must be a regular project file')
    data = json.loads(checkpoint.read_text())
    if data.get('profile') == 'tractanda.stash-linux-package.v1':
        return linux_package_basis(checkpoint, data)
    if data.get('profile') in ('tractanda.stash-source-approval.v1', 'tractanda.stash-source-approval.v2'):
        return source_approval_basis(checkpoint, data)
    if data.get('profile') == 'tractanda.stash-fresh-store-wiring.v1':
        return fresh_store_basis(checkpoint, data)
    if data.get('profile') == 'tractanda.stash-enrollment-target.v1':
        return enrollment_basis(checkpoint, data)
    if data.get('profile') == 'tractanda.stash-peer-credentials.v1':
        return credential_basis(checkpoint, data)
    if data.get('profile') != 'tractanda.stash-corpus-portability.v1' or data.get('baselineMacSHA256') != C.MAC_SOURCE_SHA:
        raise RuntimeError('unexpected portable source checkpoint')
    current = json.loads(checked_reference(data['macCompiledManifest']).read_text())['files']
    before, after = [{v['path']: v['sha256'] for v in rows} for rows in (baseline, current)]
    if len(before) != 1160 or len(after) != 1160:
        raise RuntimeError('portable checkpoint source count differs')
    validate_delta(before, after, data['changes'])
    if {v['sourcePath'] for v in data['preimages']} != PORTABLE_PATHS or len(data['preimages']) != 3:
        raise RuntimeError('portable checkpoint preimages differ')
    for row in data['preimages']:
        checked_reference(row)
        if row['sha256'] != before[row['sourcePath']]:
            raise RuntimeError('portable preimage does not match original Mac source')
    extra = []
    focused = []
    for name in ('PageCorpusAllocationTests', 'PageCorpusProjectionTests'):
        p = REPO / 'Tests/TractandaCoreTests' / (name + '.swift')
        cases = ['TractandaCoreTests.' + name + '.' + method for method in re.findall(r'^    func (test\w+)\(', p.read_text(), re.M)]
        focused += cases
        if name == 'PageCorpusAllocationTests':
            extra = cases
    if len(extra) != 9 or len(focused) != 17 or sorted(data['macCaseIDs']) != sorted(focused):
        raise RuntimeError('portable focused case declaration differs')
    status = json.loads(checked_reference(data['macStatus']).read_text())
    verify_mac_cases(status, checked_reference(data['macLog']).read_text(), focused)
    provenance = dict(kind='reviewed-three-path-portability', baselineMacSHA256=C.MAC_SOURCE_SHA,
        checkpointSHA256=C.sha(checkpoint), currentMacManifestSHA256=data['macCompiledManifest']['sha256'],
        unchangedBaselineInputs=1157, changes=data['changes'], focusedMacCases=focused)
    return current, provenance, extra


def linux_package_selection(selection):
    """The exact D2 Mac73->Linux55 seam excludes only the18 macOS Setup fixtures."""
    methods = selection['methods']
    classes = {'SetupTests', 'SetupServiceBackendTests', 'SetupLinuxPayloadTests', 'SetupPeerRuntimeTests',
               'SetupPackageArgumentsTests', 'SetupPackageCompatibilityTests', 'SetupPackageLifecycleTests'}
    if (selection['macCount'] != 73 or selection['linuxPortableCount'] != 55 or len(methods) != 73
            or len(set(methods)) != 73 or any(not re.fullmatch(r'[A-Za-z0-9_]+/test[A-Za-z0-9_]+', v)
                                               or v.split('/')[0] not in classes for v in methods)):
        raise RuntimeError('D2 exact73 Mac method inventory differs')
    excluded = [v for v in methods if v.startswith('SetupTests/')]
    portable = [v for v in methods if v not in excluded]
    if len(excluded) != 18 or selection['linuxMethods'] != portable or len(portable) != 55:
        raise RuntimeError('D2 portable exclusions must be exactly18 macOS Setup fixtures')
    proofs = selection['fixtureProofs']
    if (selection['fixtureProofCount'] != 48 or len(proofs) != 48
            or len({v['method'] for v in proofs}) != 48
            or any(v['method'] not in methods or v['source'] != v['method'].split('/')[0]
                   or v['source'] not in FIXTURE_SOURCES or v['proofCount'] != 1 for v in proofs)):
        raise RuntimeError('D2 candidate fixture proof mappings differ')
    proof_ids = ['TractandaSetupTests.' + v['method'].replace('/', '.') for v in proofs if v['method'] in portable]
    if selection['linuxFixtureProofCount'] != 30 or len(proof_ids) != 30:
        raise RuntimeError('D2 portable proof inventory must contain30 exact methods')
    normalize = lambda values: ['TractandaSetupTests.' + v.replace('/', '.') for v in values]
    return normalize(methods), normalize(portable), normalize(excluded), proof_ids


def linux_package_basis(checkpoint, data):
    # This finite profile is admitted only for the reviewed D2 candidate and its real Mac73
    # receipt. It does not extend the older generic exclusion/delta acceptance surfaces.
    anchors = {
        'candidate': '0087b6e2d941c53f91c83cfaff8ef8429f9f40210baa79ee8d67e8600091e4e9',
        'sourceReview': '062b37f3778d3a7efeff84a9e1ba00eb623097b7eda36bb2f370936aca124eaa',
        'macReceipt': '39b43b1592c60fc6a234bfe50472c47fd1db3147b2a7eafb21350d01eb4937b8',
        'developmentSupplement': 'c8a3e071bfa4f5c10643f0425307ca61ecb60515304bcb1f961a99bd167e2a0a',
    }
    paths = {}
    for key, digest in anchors.items():
        if data[key]['sha256'] != digest:
            raise RuntimeError('D2 reviewed evidence identity differs: ' + key)
        paths[key] = checked_reference(data[key])
    candidate = json.loads(paths['candidate'].read_text())
    for key, name in [('sourceManifest', 'source-inputs.json'), ('selection', 'selected-tests.json')]:
        if data[key]['sha256'] != candidate['references'][name]:
            raise RuntimeError('D2 candidate manifest/selection binding differs')
        paths[key] = checked_reference(data[key])
    selection = json.loads(paths['selection'].read_text())
    mac_ids, ids, excluded, proofs = linux_package_selection(selection)
    if data['expectedIDs'] != ids or data['excludedMacIDs'] != excluded:
        raise RuntimeError('D2 declared portable selection differs from candidate')
    receipt = json.loads(paths['macReceipt'].read_text())
    refs = receipt['references']
    if (receipt['status'] != 'PASS' or receipt['candidateSHA256'] != anchors['candidate']
            or receipt['reviewSHA256'] != anchors['sourceReview'] or receipt['passedMethods'] != 73
            or receipt['failures'] or receipt['skips'] or receipt['actualFixtureProofs'] != 48
            or receipt['sourceChanged'] or receipt['supportChanged']):
        raise RuntimeError('D2 accepted Mac result differs')
    for key in ('candidate', 'sourceReview', 'sourceManifest', 'selection', 'macStatus', 'macLog', 'developmentSupplement'):
        if data[key] not in refs:
            raise RuntimeError('D2 Mac receipt does not bind evidence: ' + key)
        checked_reference(data[key])
    verify_mac_cases(json.loads(checked_reference(data['macStatus']).read_text()),
                     checked_reference(data['macLog']).read_text(), mac_ids, multiple_bundles=True)
    generic = json.loads(paths['sourceManifest'].read_text())['inputs']
    if len(generic) != 1281 or len({v['path'] for v in generic}) != 1281:
        raise RuntimeError('D2 generic source inventory differs')
    supplement = json.loads(paths['developmentSupplement'].read_text())
    extra = supplement['inputs']
    if len(extra) != 4 or {v['path'] for v in extra} != DEVELOPMENT_SWIFT | DEVELOPMENT_ANCILLARY:
        raise RuntimeError('D2 custom-path development input inventory differs')
    prior = supplement['priorAcceptedStage']
    accepted = C.checked_json(REPO / prior['path'], prior['sha256'])['files']
    old = {v['path'].removeprefix('source/Tractanda/'): v['sha256'] for v in accepted}
    current = list(generic)
    for row in extra:
        if row['sha256'] != old.get(row['path']) or row['compiled'] != (row['path'] in DEVELOPMENT_SWIFT):
            raise RuntimeError('D2 custom-path input differs from accepted C2 baseline')
        checked_reference({key: row[key] for key in ('path', 'bytes', 'sha256')})
        current.append({key: row[key] for key in ('path', 'bytes', 'sha256')})
    if len({v['path'] for v in current}) != 1285:
        raise RuntimeError('D2 complete staged input paths overlap')
    support = data['linuxSupportInputs']
    if not isinstance(support, list) or len(support) != 3 or {v['path'] for v in support} != {'scripts/' + v for v in SUPPORT}:
        raise RuntimeError('D2 exact Linux support bindings differ')
    for row in support:
        checked_reference(row)
    return current, dict(kind='reviewed-linux-package', checkpointSHA256=C.sha(checkpoint),
        candidateSHA256=anchors['candidate'], currentMacReceiptSHA256=anchors['macReceipt'],
        sourceInputs=1285, genericMacInputs=1281, explicitDevelopmentCompilerInputs=2,
        excludedDevelopmentAncillaries=2, exactFocusedIDs=ids, excludedMacIDs=excluded,
        fixtureProofIDs=proofs, acceptedMacCases=73, singleCleanMacInvocation=True,
        linuxSupportInputs={v['path']:v['sha256'] for v in support},
        separateTestStderr=True, packageTests=[],
        qualification='Custom-path files match prior C2/current hashes; outside D2 generic Mac before/after witness.'), []


def validate_credential_delta(before, after, receipt):
    if len(before) != 1160 or len(after) != 1162 or set(after) - set(before) != CREDENTIAL_ADDED or set(before) - set(after):
        raise RuntimeError('credential inventory must add exactly the two approved files')
    changed = {p for p in before if before[p] != after[p]}
    rows = receipt['preimages']
    if changed != CREDENTIAL_MODIFIED or len(rows) != 7 or {r['path'] for r in rows} != CREDENTIAL_MODIFIED:
        raise RuntimeError('credential modified paths differ')
    for row in rows:
        if row['preimage_sha256'] != before[row['path']] or row['current_sha256'] != after[row['path']]:
            raise RuntimeError('credential preimage/current hash differs')
    for path in CREDENTIAL_ADDED:
        if receipt['references'][path]['sha256'] != after[path]:
            raise RuntimeError('credential added-file hash differs')


def credential_basis(checkpoint, data):
    expected = {
        'priorCheckpoint': '398d4bb85190859e84761c040753ee3dcb309599226ffabeb4d6436c8e798ef4',
        'priorStashReceipt': '9456f6762ec45365a3d6aea2d7f82a566f7c01d5d6aac99a520be4a2883f636c',
        'credentialReceipt': '19b19891704990a568ec1ac3b69dce758f7b9f85bb9ec4cad95ec6147039e1f4',
        'credentialReview': 'd989420e17b4944077dc79277a57982b7af84eb754b654de7aecc2aae6673611',
    }
    paths = {}
    for key, digest in expected.items():
        if data[key]['sha256'] != digest:
            raise RuntimeError('credential checkpoint authority differs: ' + key)
        paths[key] = checked_reference(data[key])
    old, _, _ = source_basis(paths['priorCheckpoint'])
    receipt = json.loads(paths['credentialReceipt'].read_text())
    for path, row in receipt['references'].items():
        checked_reference(dict(row, path=path))
    manifest = data['currentMacManifest']
    if manifest['path'] != receipt['runs'][-1]['source_manifest'] or manifest['sha256'] != receipt['references'][manifest['path']]['sha256']:
        raise RuntimeError('credential final compiled manifest differs')
    current = json.loads(checked_reference(manifest).read_text())['files']
    before, after = [{v['path']: v['sha256'] for v in rows} for rows in (old, current)]
    if len(current) != 1162:
        raise RuntimeError('duplicate credential source input')
    validate_credential_delta(before, after, receipt)
    cases = receipt['currentDistinctOutcomes']['cases']
    focused = [v['suite'] + '.' + v['method'] for v in cases]
    if len(focused) != 41 or len(set(focused)) != 41 or any(v['outcome'] != 'passed' for v in cases):
        raise RuntimeError('credential accepted Mac outcomes differ')
    prior = json.loads(paths['priorStashReceipt'].read_text())['stash']['exactIDs']
    ids = sorted(set(prior) | set(focused))
    if len(prior) != 125 or len(set(prior)) != 125 or ids != data['expectedIDs'] or len(ids) != 163:
        raise RuntimeError('credential union selection differs')
    baseline_ids, _ = C.checked_selection(C.checked_json(REPO / C.MAC_RECEIPT, C.MAC_RECEIPT_SHA))
    provenance = dict(kind='reviewed-peer-credentials', checkpointSHA256=C.sha(checkpoint),
        credentialReceiptSHA256=expected['credentialReceipt'], credentialReviewSHA256=expected['credentialReview'],
        currentMacManifestSHA256=manifest['sha256'], sourceInputs=1162, expectedStashCases=len(ids),
        unchangedPriorInputs=1153, modified=receipt['preimages'], added=sorted(CREDENTIAL_ADDED),
        focusedMacCases=focused, priorStashCases=125)
    return current, provenance, sorted(set(ids) - set(baseline_ids))


def validate_enrollment_delta(before, after, preimages, receipt):
    if len(before) != 1162 or len(after) != 1164 or set(after) - set(before) != ENROLLMENT_ADDED or set(before) - set(after):
        raise RuntimeError('enrollment inventory must add exactly the two approved files')
    if {p for p in before if before[p] != after[p]} != ENROLLMENT_MODIFIED:
        raise RuntimeError('enrollment modified paths differ')
    if len(preimages) != 2 or {v['sourcePath'] for v in preimages} != ENROLLMENT_MODIFIED:
        raise RuntimeError('enrollment preimage set differs')
    for row in preimages:
        if row['sha256'] != before[row['sourcePath']]:
            raise RuntimeError('enrollment preimage hash differs')
    if set(receipt['ownedSource']) != ENROLLMENT_MODIFIED | ENROLLMENT_ADDED:
        raise RuntimeError('enrollment owned source set differs')
    if any(after[p] != digest for p, digest in receipt['ownedSource'].items()):
        raise RuntimeError('enrollment current source hash differs')


def enrollment_basis(checkpoint, data):
    expected = {
        'priorStashReceipt': '6341eab1a65d60cd282b020f3c22059c98a1be5ba7662c6a7c9b17bae6c4ca38',
        'enrollmentReceipt': '1ce3e76a936eb80a2734bef67213a4178c159c33d04c1c71f2931088f0ac46c0',
        'enrollmentReview': '2315b316fe90e5d313b312cbe7d11590b40643137d843ee05452ed41b314703a',
    }
    paths = {}
    for key, digest in expected.items():
        if data[key]['sha256'] != digest:
            raise RuntimeError('enrollment checkpoint authority differs: ' + key)
        paths[key] = checked_reference(data[key])
    prior = json.loads(paths['priorStashReceipt'].read_text())
    if prior['result'] != 'PASS' or prior['currentMacInputs'] != 1162:
        raise RuntimeError('prior accepted Linux baseline differs')
    prior_checkpoint = json.loads(checked_reference(prior['sourceCheckpoint']).read_text())
    old = json.loads(checked_reference(prior_checkpoint['currentMacManifest']).read_text())['files']
    receipt = json.loads(paths['enrollmentReceipt'].read_text())
    for path, row in receipt['references'].items():
        checked_reference(dict(row, path=path))
    manifest_path = 'work/shared-authority-20261015/logs/enrollment-target-macos-source.json'
    manifest = dict(receipt['references'][manifest_path], path=manifest_path)
    current = json.loads(checked_reference(manifest).read_text())['files']
    before, after = [{v['path']: v['sha256'] for v in rows} for rows in (old, current)]
    if len(old) != 1162 or len(current) != 1164:
        raise RuntimeError('duplicate enrollment source input')
    validate_enrollment_delta(before, after, data['preimages'], receipt)
    for row in data['preimages']:
        checked_reference(row)
    focused = [v['suite'] + '.' + v['method'] for v in receipt['cases']]
    source_tests = (REPO / 'Tests/TractandaCoreTests/PeerEnrollmentTests.swift').read_text()
    actual = ['TractandaCoreTests.PeerEnrollmentTests.' + method for method in re.findall(r'^    func (test\w+)\(', source_tests, re.M)]
    if len(focused) != 12 or len(set(focused)) != 12 or sorted(focused) != sorted(actual) or any(v['outcome'] != 'passed' for v in receipt['cases']):
        raise RuntimeError('enrollment accepted Mac cases differ')
    refs = receipt['references']
    status_path = 'work/shared-authority-20261015/logs/enrollment-target-macos.status.json'
    log_path = 'work/shared-authority-20261015/logs/enrollment-target-macos.log'
    verify_mac_cases(json.loads(checked_reference(dict(refs[status_path], path=status_path)).read_text()),
                     checked_reference(dict(refs[log_path], path=log_path)).read_text(), focused)
    ids = sorted(set(focused) | ENROLLMENT_REGRESSIONS)
    if len(ids) != 21 or data['expectedIDs'] != ids:
        raise RuntimeError('enrollment exact focused selection differs')
    for case in ENROLLMENT_REGRESSIONS:
        module, suite, method = case.split('.')
        source = (REPO / 'Tests' / module / (suite + '.swift')).read_text()
        if not re.search(r'^    func ' + re.escape(method) + r'\(', source, re.M):
            raise RuntimeError('enrollment regression source case absent')
    return current, dict(kind='reviewed-enrollment-target', checkpointSHA256=C.sha(checkpoint),
        sourceInputs=1164, unchangedPriorInputs=1160, priorStashReceiptSHA256=expected['priorStashReceipt'],
        enrollmentReceiptSHA256=expected['enrollmentReceipt'], enrollmentReviewSHA256=expected['enrollmentReview'],
        currentMacManifestSHA256=manifest['sha256'], modified=sorted(ENROLLMENT_MODIFIED), added=sorted(ENROLLMENT_ADDED),
        focusedMacCases=focused, regressionCases=sorted(ENROLLMENT_REGRESSIONS), exactFocusedIDs=ids), []


def digest_reference(reference):
    # Mac receipts bind hashes but not lengths; use their immutable SHA256 authority.
    path = safe_target(REPO, reference['path'])
    return checked_reference(dict(reference, bytes=path.stat().st_size))


def normalize_batch_method(method):
    method = method.replace('/', '.')
    if method.count('.') == 1:
        source = method.split('.')[0]
        module = {'PeerCredentialCommandTests': 'TractandaCLITests',
                  'PeerEnrollmentCommandTests': 'TractandaCLITests',
                  'PeerEnrollmentActivateCommandTests': 'TractandaCLITests',
                  'PeerTargetActivationArgumentsTests': 'TractandaSetupTests',
                  'SetupPeerRuntimeArgumentsTests': 'TractandaSetupTests',
                  'DaemonApplicationTests': 'TractandaServerTests'}.get(
                      source, FIXTURE_SOURCES.get(source, ('TractandaCoreTests', ''))[0])
        method = module + '.' + method
    # The development fixture is a separate SwiftPM test target on both OSes.
    method = method.replace('TractandaCoreTests.DevelopmentFirstSourceFixtureTests.',
                            'FirstSourceConversionTests.DevelopmentFirstSourceFixtureTests.')
    if not re.fullmatch(r'[A-Za-z0-9_]+\.[A-Za-z0-9_]+\.test[A-Za-z0-9_]+', method):
        raise RuntimeError('reviewed batch method spelling differs')
    return method


def method_list(reference):
    path = checked_reference(reference)
    text = path.read_text()
    values = json.loads(text) if text.lstrip().startswith('[') else text.splitlines()
    if not isinstance(values, list) or not values or not all(isinstance(v, str) and v.strip() == v and v for v in values):
        raise RuntimeError('reviewed selector is not an exact nonempty method list')
    ids = sorted(normalize_batch_method(v) for v in values)
    if len(ids) != len(set(ids)):
        raise RuntimeError('reviewed selector contains duplicate methods')
    return ids


def receipt_references(receipt):
    rows = receipt.get('references', receipt.get('evidence'))
    if rows is None:
        rows = [receipt[key] for key in ('candidate','sourceBefore','sourceAfter','nativeStatus','nativeLog')]
    result = []
    for row in rows:
        size = row.get('bytes', row.get('size'))
        if 'bytes' not in row and 'size' not in row:
            path = safe_target(REPO, row['path'])
            size = path.stat().st_size
            if not 0 <= size <= RESULT_CAP:
                raise RuntimeError('hash-only receipt reference exceeds bounded evidence size')
            digest_reference(row)
        result.append(dict(path=row['path'], bytes=size, sha256=row['sha256']))
    if len({r['path'] for r in result}) != len(result) or any(type(r['bytes']) is not int for r in result):
        raise RuntimeError('receipt reference inventory differs')
    return result


def candidate_rows(candidate):
    rows = candidate.get('files', candidate.get('inputs'))
    if not isinstance(rows, list) or len({r['path'] for r in rows}) != len(rows):
        raise RuntimeError('reviewed source candidate input inventory differs')
    return rows


# Existing focused-v2 seam: only these reviewed mock installer cases join the old ACL case.
MANAGED_MAC_ONLY = {
    'testFailureAfterEmbeddingStartupRollsBackBothJobs',
    'testInstallUpgradeRollbackAndUninstallUseOwnedReceiptsAndCreateNoAccount',
    'testManagedPeerCanonicalIncompatibleRollbackKeepsSnapshotAndServicesStopped',
    'testManagedPeerDisabledRetryAfterLeafRemovalCommitsWithoutReactivation',
    'testManagedPeerFailureBeforeAndAfterPublicationRestoresExactConfiguration',
    'testManagedPeerFreshDisabledReplacePreserveDisableAndOmittedUpgrade',
    'testManagedPeerLoadedThenDiskDriftCannotCommitOrAutostartAndStopIgnoresDrift',
    'testManagedPeerStartRefusesDriftWithoutBootstrapAndUninstallRemovesOnlyOwnedSettings',
}


def focused_mac_exclusions(data, mac_ids):
    focused = data.get('focusedCurrentMac')
    if focused is None:
        return None
    if not isinstance(focused, dict) or set(focused) != {'excludedMacTests'}:
        raise RuntimeError('focused current Mac selection declaration differs')
    rows = focused['excludedMacTests']
    if not isinstance(rows, list) or len(rows) > 9:
        raise RuntimeError('focused Mac-only exclusions exceed reviewed scope')
    excluded = set()
    acl_id = 'TractandaCoreTests.PeerPrivateCredentialInputTests.testMode600WithExtendedACLIsRejected'
    allowed = {acl_id: 'Tests/TractandaCoreTests/PeerPrivateCredentialInputTests.swift'}
    allowed.update({'TractandaSetupTests.SetupTests.' + name: 'Tests/TractandaSetupTests/SetupTests.swift'
                    for name in MANAGED_MAC_ONLY})
    for row in rows:
        if (not isinstance(row, dict) or set(row) != {'id', 'source', 'reason'}
                or row['id'] not in allowed or row['source'] != allowed[row['id']]
                or not isinstance(row['reason'], str) or not 1 <= len(row['reason']) <= 256
                or not row['reason'].isprintable() or row['id'] not in mac_ids or row['id'] in excluded):
            raise RuntimeError('focused Mac-only exclusion is not the reviewed conditional case')
        source = row['source']
        candidate = json.loads(checked_reference(data['candidate']).read_text())
        committed = next((r for r in candidate_rows(candidate) if r['path'] == source), None)
        path = safe_target(REPO, source)
        if committed is None or C.sha(path) != committed['sha256']:
            raise RuntimeError('focused Mac-only source is not candidate-bound')
        text = path.read_text()
        method = row['id'].rsplit('.', 1)[1]
        if len(re.findall(r'^    func ' + re.escape(method) + r'\(', text, re.M)) != 1:
            raise RuntimeError('focused exclusion method is not unique in bound source')
        if row['id'] == acl_id:
            needle = '#if os(macOS)\n    func testMode600WithExtendedACLIsRejected()'
            if text.count(needle) != 1:
                raise RuntimeError('focused exclusion is not the bound macOS-conditional method')
        else:
            fixture_guard = ('    private func fixture() throws -> Fixture {\n'
                             '        #if !os(macOS)\n'
                             '            throw XCTSkip("Managed macOS installation tests; Linux installer remains in development.")\n'
                             '        #endif')
            if text.count(fixture_guard) != 1:
                raise RuntimeError('managed installer exclusion lacks its bound nonmacOS fixture skip')
            body = text.split('    func ' + method + '(', 1)[1].split('\n    func ', 1)[0]
            if 'try fixture()' not in body:
                raise RuntimeError('managed installer exclusion does not use the guarded fixture')
        excluded.add(row['id'])
    return excluded


def reviewed_batch_selection(data, mac_ids):
    if data.get('focusedCurrentMac') is not None and any(k in data for k in ('priorUnitReceipt', 'retainedRootRuntime')):
        raise RuntimeError('focused current Mac cannot mix retained unit accounting')
    if 'priorUnitReceipt' in data:
        accepted = json.loads(checked_reference(data['priorUnitReceipt']).read_text())
        checked_reference(data['priorUnitReview'])
        prior_ids = method_list(data['priorUnitExpectedTests'])
        coverage = accepted['coverage']
        if coverage['uniquePassedMethods'] != len(prior_ids) or coverage['missingMethods'] or coverage['extraMethods'] or accepted['candidateSHA256'] != data['reviewedCandidates'][0]['sha256']:
            raise RuntimeError('reviewed predecessor unit coverage differs')
    else:
        accepted = json.loads(checked_reference(data['priorStashReceipt']).read_text())
        prior_ids = accepted['exactIDs']
        if accepted['result'] != 'PASS' or accepted['passed'] != len(prior_ids) or len(set(prior_ids)) != len(prior_ids) or accepted['failed'] or accepted['skipped']:
            raise RuntimeError('reviewed predecessor Linux coverage differs')
    ids = method_list(data['expectedTests'])
    if 'retainedRootRuntime' in data:
        prior = retained_runtime(data)
        if ids != mac_ids or not set(prior['failedIDs']).issubset(ids) or not set(prior_ids).issubset(set(prior['passedIDs']) | set(ids)):
            raise RuntimeError('focused selection does not preserve retained pass/failure accounting')
    elif data.get('focusedCurrentMac') is not None:
        excluded = focused_mac_exclusions(data, mac_ids)
        if ids != sorted(set(mac_ids) - excluded):
            raise RuntimeError('focused current Mac exact method selection differs')
    elif ids != sorted(set(prior_ids) | set(mac_ids)):
        raise RuntimeError('reviewed source exact method union differs')
    if len(ids) != data['batch']['expectedCases']:
        raise RuntimeError('reviewed source exact method count differs')
    return ids


def retained_runtime(data):
    result = json.loads(checked_reference(data['retainedRootRuntime']).read_text())
    runtime = result['rootRuntime']
    if result['schema'] != 'tractanda.target-activation-linux-failed-verification.v1' or runtime['rawExit'] != 1 or runtime['failedMethods'] != 1 or runtime['skippedMethods'] or len(runtime['failedIDs']) != 1 or runtime['passedMethods'] != len(runtime['passedIDs']) or len(set(runtime['passedIDs'])) != len(runtime['passedIDs']) or set(runtime['passedIDs']) & set(runtime['failedIDs']):
        raise RuntimeError('retained failed-run method accounting differs')
    if runtime['executedMethods'] != len(runtime['passedIDs']) + len(runtime['failedIDs']) or not result['closure']['allOwnedProcessesClosed']:
        raise RuntimeError('retained failed-run closure differs')
    return runtime


def retained_fixture_delta(data, current, candidate):
    result = json.loads(checked_reference(data['retainedRootRuntime']).read_text())
    prior = json.loads(checked_reference(result['source']['closure']).read_text())
    before = {r['path']:r['sha256'] for r in prior['files']}
    after = {r['path']:r['sha256'] for r in current}
    delta = candidate['sourceDelta']
    patch = delta['patch']
    declared = dict(path=patch['path'], bytes=patch.get('bytes',patch.get('size')), sha256=patch['sha256'])
    if data['retainedFixtureDelta'] != declared:
        raise RuntimeError('retained fixture patch reference differs')
    checked_reference(declared)
    changed = {p for p in before if before[p] != after.get(p)}
    if set(before) != set(after) or delta['added'] or delta['removed'] or changed != set(delta['changed']) or len(changed) != 1 or not all(p.startswith('Tests/') and p.endswith('.swift') for p in changed):
        raise RuntimeError('retained passes require the sole reviewed fixture-only source delta')
    selected_files = {'Tests/'+case.split('.')[0]+'/'+case.split('.')[1]+'.swift' for case in data['expectedIDs']}
    if not changed.issubset(selected_files):
        raise RuntimeError('changed fixture source is outside focused selected methods')
    return dict(receiptSHA256=data['retainedRootRuntime']['sha256'], passedMethods=len(retained_runtime(data)['passedIDs']),
                fixturePatchSHA256=declared['sha256'], changedFixturePaths=sorted(changed))


def reviewed_batch_inputs(data, candidate, current, receipt_refs):
    witnesses = []
    for key in ('macCompleteBefore', 'macCompleteAfter'):
        row = data[key]
        if row not in receipt_refs:
            raise RuntimeError('reviewed source complete witness reference differs')
        witnesses.append(json.loads(checked_reference(row).read_text()))
    before, after = witnesses
    if before['files'] != after['files'] or after['changed'] or after['nativeExit'] != 0 or any(w['candidateSHA256'] != data['candidate']['sha256'] or set(w['explicitDevelopmentInputs']) != DEVELOPMENT_SWIFT for w in witnesses):
        raise RuntimeError('reviewed source complete before/after witness differs')
    complete = {r['path']:r['sha256'] for r in before['files']}
    if len(complete) != len(before['files']) or any(complete.get(r['path']) != r['sha256'] for r in current):
        raise RuntimeError('reviewed source generic/complete input commitment differs')
    source_paths = {r['path'] for r in current} | DEVELOPMENT_SWIFT
    reviewed = {}
    if not data['reviewedCandidates'] or len({r['path'] for r in data['reviewedCandidates']}) != len(data['reviewedCandidates']) or data['reviewedCandidates'][-1] != data['candidate']:
        raise RuntimeError('reviewed source ordered candidate references differ')
    for ref in data['reviewedCandidates']:
        rows = candidate_rows(json.loads(checked_reference(ref).read_text()))
        reviewed.update({r['path']:r['sha256'] for r in rows if r['path'] in source_paths})
    final = {r['path']:r['sha256'] for r in candidate_rows(candidate)}
    if not DEVELOPMENT_SWIFT.issubset(final) or any(complete.get(p) != final[p] for p in DEVELOPMENT_SWIFT):
        raise RuntimeError('reviewed source explicit development inputs differ')
    return reviewed, {p:final[p] for p in sorted(DEVELOPMENT_SWIFT)}


def reviewed_fixture_proof_ids(data, candidate, selected_ids):
    reference = data.get('fixtureProofTests')
    if reference is None:
        if 'fixtureProofCases' in data.get('batch', {}):
            raise RuntimeError('declared fixture proof subset reference is absent')
        return []
    count = data.get('batch', {}).get('fixtureProofCases')
    if not isinstance(reference, dict) or type(count) is not int or not 0 < count <= 512 or type(reference.get('bytes')) is not int or not 0 < reference['bytes'] <= 64 * 1024:
        raise RuntimeError('reviewed fixture proof subset bounds differ')
    committed = next((row for row in candidate_rows(candidate) if row['path'] == reference['path']), None)
    if committed is None or committed['sha256'] != reference['sha256'] or committed.get('size', committed.get('bytes')) != reference['bytes']:
        raise RuntimeError('fixture proof subset is not bound by the accepted Mac candidate')
    values = json.loads(checked_reference(reference).read_text())
    if not isinstance(values, list) or not 0 < len(values) <= 512 or not all(isinstance(v, str) and re.fullmatch(r'[A-Za-z0-9_]+\.test[A-Za-z0-9_]+', v) for v in values) or len(set(values)) != len(values):
        raise RuntimeError('reviewed fixture proof subset inventory differs')
    ids = []
    for value in values:
        source = value.split('.')[0]
        if source not in FIXTURE_SOURCES:
            raise RuntimeError('reviewed fixture proof source is unknown')
        ids.append(FIXTURE_SOURCES[source][0] + '.' + value)
    excluded = focused_mac_exclusions(data, method_list(data['macExpectedTests'])) if data.get('focusedCurrentMac') is not None else set()
    ids = [value for value in ids if value not in excluded]
    if len(ids) != count:
        raise RuntimeError('reviewed fixture proof subset inventory differs')
    if not set(ids).issubset(selected_ids):
        raise RuntimeError('reviewed fixture proof case is outside the native selection')
    return sorted(ids)


def reviewed_linux_support(data, candidate):
    # These two Linux-only support scripts are excluded from the generic Mac
    # compiled inventory. Never route a compiled/runtime input through this seam.
    allowed = {'scripts/verify-stash-cluster.py', 'scripts/verify-cluster-linux.py'}
    frozen = {row['path']: row['sha256'] for row in json.loads(checked_reference(data['macCompleteBefore']).read_text())['files']}
    committed = {row['path']: row['sha256'] for row in candidate_rows(candidate)}
    paths = {'scripts/' + name for name in SUPPORT} & frozen.keys()
    current = {path: C.sha(safe_target(REPO, path)) for path in sorted(paths)}
    changed = {path for path in paths if frozen[path] != current[path]}
    declaration = data.get('linuxSupportDelta')
    if not changed:
        if declaration is not None:
            raise RuntimeError('Linux support delta declared without a current difference')
        return current, None
    if not changed.issubset(allowed) or declaration is None or set(declaration) != {'changes', 'patch', 'review'}:
        raise RuntimeError('changed Linux support needs its exact reviewed v2 delta')
    rows = declaration['changes']
    if not isinstance(rows, list) or len(rows) != len(changed) or any(not isinstance(row, dict) or set(row) != {'path', 'beforeSHA256', 'afterSHA256'} for row in rows) or {row['path'] for row in rows} != changed:
        raise RuntimeError('reviewed Linux support path set differs')
    for row in rows:
        path = row['path']
        if row['beforeSHA256'] != frozen[path] or committed.get(path) != frozen[path] or row['afterSHA256'] != current[path]:
            raise RuntimeError('reviewed Linux support old/new hash differs')
    for key in ('patch', 'review'):
        reference = declaration[key]
        if type(reference.get('bytes')) is not int or not 0 < reference['bytes'] <= 1024 * 1024:
            raise RuntimeError('reviewed Linux support evidence exceeds its bound')
        checked_reference(reference)
    return current, dict(changes=rows, patch=declaration['patch'], review=declaration['review'],
                         separatelyReviewedLinuxHarness=True, testedByMacInvocation=False)


def fixture_proof_ids(provenance):
    if provenance['kind'] == 'reviewed-fresh-store-wiring':
        return provenance['fixturePortability']['exactMacCases']
    if provenance['kind'] in ('reviewed-source-approval', 'reviewed-linux-package'):
        return provenance.get('fixtureProofIDs', [])
    return []


def reviewed_package_tests(data, current):
    scopes = data.get('packageTests', [])
    if len(scopes) > 1:
        raise RuntimeError('only the bounded PeerTLS package scope is admitted')
    results = []
    for scope in scopes:
        if scope['name'] != 'peer-tls' or scope['packagePath'] != 'Packages/TractandaPeerTLS':
            raise RuntimeError('unexpected nested package scope')
        ids = method_list(scope['expectedTests'])
        if any(not case.startswith('TractandaPeerTLSTests.') for case in ids):
            raise RuntimeError('package selector crosses its test target')
        receipt = json.loads(checked_reference(scope['macReceipt']).read_text())
        checked_reference(scope['macReview'])
        refs = receipt_references(receipt)
        for key in ('candidate', 'macStatus', 'macLog', 'macCompleteBefore', 'macCompleteAfter'):
            if scope[key] not in refs:
                raise RuntimeError('package Mac receipt reference differs: ' + key)
            checked_reference(scope[key])
        accepted = receipt['result']
        if receipt['candidate'] != scope['candidate'] or accepted['passed'] != len(ids) or accepted['failed'] or accepted['skipped'] or accepted['exit'] or sorted(normalize_batch_method(v) for v in accepted['executedMethods']) != ids:
            raise RuntimeError('package Mac accepted method inventory differs')
        verify_mac_cases(json.loads(checked_reference(scope['macStatus']).read_text()),
                         checked_reference(scope['macLog']).read_text(), ids, multiple_bundles=True)
        before, after = [json.loads(checked_reference(scope[key]).read_text())
                         for key in ('macCompleteBefore', 'macCompleteAfter')]
        if before['files'] != after['files'] or after['changed'] or any(w['candidateSHA256'] != scope['candidate']['sha256'] for w in (before, after)):
            raise RuntimeError('package Mac complete input witness differs')
        committed = {r['path']:r['sha256'] for r in before['files']}
        prefix = scope['packagePath'] + '/'
        compiled = {r['path']:r['sha256'] for r in current if r['path'] in (prefix+'Package.swift', prefix+'Package.resolved') or r['path'].startswith((prefix+'Sources/', prefix+'Tests/'))}
        witnessed = {p:digest for p,digest in committed.items() if p in (prefix+'Package.swift', prefix+'Package.resolved') or p.startswith((prefix+'Sources/', prefix+'Tests/'))}
        if not compiled or compiled != witnessed or len(committed) != len(before['files']):
            raise RuntimeError('package source/header/resource closure differs from accepted Mac scope')
        pins = json.loads((REPO / prefix / 'Package.resolved').read_text())['pins']
        dependencies = {p['identity']:(p['revision'], p['version']) for p in before['dependencies']}
        if before['dependencies'] != after['dependencies'] or len(dependencies) != len(before['dependencies']) or dependencies != {p['identity']:(p['state']['revision'], p['state']['version']) for p in pins}:
            raise RuntimeError('package accepted dependency revisions differ from its frozen lock')
        results.append(dict(name=scope['name'], packagePath=scope['packagePath'], ids=ids,
                            testFilter=exact_filter(ids), pins=pins, mirrorPrefix='mirrors/peer-tls/',
                            macReceiptSHA256=scope['macReceipt']['sha256'], compiledInputs=len(compiled)))
    return results


def exact_filter(ids):
    return '^(?:' + '|'.join(re.escape(v.rsplit('.', 1)[0]) + '/' + v.rsplit('.', 1)[1] for v in ids) + ')$'


def validate_source_approval_delta(before, current, candidate, counts=None):
    counts = counts or dict(priorInputs=1174, currentInputs=1176, addedInputs=2, modifiedInputs=16)
    after = {r['path']:r['sha256'] for r in current}
    added = set(after)-set(before)
    modified = {p for p in before if p in after and before[p] != after[p]}
    reviewed_delta = {p for p,digest in candidate.items() if before.get(p) != digest}
    if len(before) != counts['priorInputs'] or len(after) != counts['currentInputs'] or len(current) != counts['currentInputs'] or set(before)-set(after) or len(added) != counts['addedInputs'] or len(modified) != counts['modifiedInputs'] or added | modified != reviewed_delta:
        raise RuntimeError('source approval complete source delta differs')
    if any(after[p] != digest for p,digest in candidate.items()):
        raise RuntimeError('source approval candidate byte commitment differs')
    return after, added, modified


def source_approval_basis(checkpoint, data):
    # v2 is the same cold-run contract with recipe-bound accepted predecessor,
    # candidate union and counts. The reviewed recipe is the admission authority.
    batch = data.get('batch') if data['profile'].endswith('.v2') else None
    if data['profile'].endswith('.v2') and not isinstance(batch, dict):
        raise RuntimeError('reviewed source batch parameters absent')
    prior_path = checked_reference(data['priorStashReceipt'])
    if batch:
        checked_reference(data['priorStashReview'])
    if not batch and C.sha(prior_path) != '63c0951339d8ea1328c75954e1632c39f3a39b2daa99e25248c0e64fea4d90e5':
        raise RuntimeError('source approval prior Linux authority differs')
    prior = json.loads(prior_path.read_text())
    stage_ref = data['priorStage']
    prior_refs = {r['path']:{k:v for k,v in r.items() if k != 'path'} for r in prior['references']} if batch else prior['references']
    prior_count = prior['source']['projectFrozenInputs'] if batch else prior['source']['frozenInputs']
    if prior['result'] != ('PASS' if batch else 'PASS_AFTER_CAPTURE_AND_POSTCHECK_RECOVERY') or prior_count != (batch['priorInputs'] if batch else 1174) or prior_refs.get(stage_ref['path']) != {k:v for k,v in stage_ref.items() if k != 'path'}:
        raise RuntimeError('source approval prior stage authority differs')
    stage = json.loads(checked_reference(stage_ref).read_text())
    before = {r['path'].removeprefix('source/Tractanda/'):r['sha256'] for r in stage['files'] if r['path'].startswith('source/Tractanda/')}
    candidate_path = checked_reference(data['candidate'])
    if not batch and C.sha(candidate_path) != 'f055c33b5cff1e08b2fea3877db97103e86cffd05d9a4052c693468f4f748029':
        raise RuntimeError('source approval candidate authority differs')
    candidate = json.loads(candidate_path.read_text())
    methods_path = checked_reference(data['macExpectedTests'] if batch else data['expectedTests'])
    selector = candidate.get('expectedMethods') if batch else None
    expected_selector = selector['sha256'] if selector else candidate['selectorSHA256' if batch else 'expectedListSHA256']
    if C.sha(methods_path) != expected_selector or (selector and selector['path'] != data['macExpectedTests']['path']):
        raise RuntimeError('source approval expected method authority differs')
    mac_ids = method_list(data['macExpectedTests']) if batch else sorted(method.replace('/', '.') for method in json.loads(methods_path.read_text()))
    selector_count = selector.get('count') if selector else None
    if selector and 'count' not in selector:
        # A standard immutable selector reference already binds its exact content.
        # Derive only its redundant count; never relax the reference or raw-case checks.
        if set(selector) != {'path', 'bytes', 'sha256'} or type(selector['bytes']) is not int or selector['bytes'] != methods_path.stat().st_size:
            raise RuntimeError('source approval candidate selector reference differs')
        selector_count = len(mac_ids)
    if selector and selector_count != len(mac_ids):
        raise RuntimeError('source approval candidate selector count differs')
    ids = reviewed_batch_selection(data, mac_ids) if batch else mac_ids
    if len(mac_ids) != (batch['acceptedMacCases'] if batch else 54) or len(set(mac_ids)) != len(mac_ids) or data['expectedIDs'] != ids:
        raise RuntimeError('source approval exact method selection differs')
    # Root admits this exact receipt/review pair separately. Bind all raw native
    # artifacts and check the actual pass events, rather than trusting a count.
    receipt = json.loads(checked_reference(data['currentMacReceipt']).read_text())
    checked_reference(data['currentMacReview'])
    refs = receipt_references(receipt) if batch else receipt['evidence']
    candidate_digest = receipt.get('candidateSHA256')
    if batch and candidate_digest is None:
        candidate_digest = next((r['sha256'] for r in refs if r['path'] == data['candidate']['path']), None)
    if (not batch and C.sha(checked_reference(data['currentMacReceipt'])) != '70784c3014b88ea8f5b3bd6b1174cb4dc222fe669ddb53dd18f7c3be082d44a1') or candidate_digest != C.sha(candidate_path):
        raise RuntimeError('source approval Mac result authority differs')
    for key in ('candidate', 'expectedTests', 'macCompiledManifest', 'macStatus', 'macLog'):
        row = data['macExpectedTests'] if batch and key == 'expectedTests' else data[key]
        if row not in refs:
            # A selector may be committed by the candidate, and the generic
            # inventory may be derived from the complete witnesses checked below.
            candidate_selector = batch and key == 'expectedTests' and selector and selector['path'] == row['path'] and selector['sha256'] == row['sha256']
            complete_inventory = batch and key == 'macCompiledManifest' and all(data[k] in refs for k in ('macCompleteBefore','macCompleteAfter'))
            if not (candidate_selector or complete_inventory):
                raise RuntimeError('source approval Mac receipt reference differs: '+key)
        checked_reference(row)
    verify_mac_cases(json.loads(checked_reference(data['macStatus']).read_text()),checked_reference(data['macLog']).read_text(),mac_ids,multiple_bundles=True)
    current = json.loads(checked_reference(data['macCompiledManifest']).read_text())['files']
    if len(current) != (batch['genericMacInputs'] if batch else 1172):
        raise RuntimeError('source approval Mac compilation inventory differs')
    # Selected conversion fixture tests compile through these exact additional
    # Swift inputs, independently bound by the reviewed candidate.
    # The two ancillary inputs remain unchanged and are not compiled by this target.
    if batch:
        reviewed, extra = reviewed_batch_inputs(data, candidate, current, refs)
    else:
        reviewed, extra = candidate['files'], candidate['extraCompiledInputs']
    if set(extra) != DEVELOPMENT_SWIFT or (not batch and len(candidate['files']) != 17):
        raise RuntimeError('source approval development inputs differ')
    current += [dict(path=p, sha256=digest) for p,digest in sorted(extra.items())]
    current += [dict(path=p, sha256=before[p]) for p in sorted(DEVELOPMENT_ANCILLARY)]
    packages = reviewed_package_tests(data, current) if batch else []
    retained = retained_fixture_delta(data, current, candidate) if 'retainedRootRuntime' in data else None
    after, added, modified = validate_source_approval_delta(before, current, dict(reviewed, **extra), batch)
    proof_ids = reviewed_fixture_proof_ids(data, candidate, ids) if batch else []
    support, support_delta = reviewed_linux_support(data, candidate) if batch else ({}, None)
    return current, dict(kind='reviewed-source-approval', checkpointSHA256=C.sha(checkpoint), sourceInputs=len(current),
        priorStashReceiptSHA256=C.sha(prior_path), priorStageSHA256=stage_ref['sha256'],
        currentMacReceiptSHA256=data['currentMacReceipt']['sha256'], currentMacReviewSHA256=data['currentMacReview']['sha256'],
        currentMacManifestSHA256=data['macCompiledManifest']['sha256'], candidateSHA256=C.sha(candidate_path),
        modified={p:dict(beforeSHA256=before[p],afterSHA256=after[p]) for p in sorted(modified)},
        added={p:after[p] for p in sorted(added)}, unchangedPriorInputs=len(before)-len(modified),
        explicitDevelopmentInputs=[dict(path=p,sha256=digest) for p,digest in sorted(extra.items())],
        excludedDevelopmentAncillaries=[dict(path=p,sha256=before[p]) for p in sorted(DEVELOPMENT_ANCILLARY)],
        exactFocusedIDs=ids, packageTests=packages, retainedRuntime=retained, fixtureProofIDs=proof_ids,
        fixtureProofTests=data.get('fixtureProofTests'),
        linuxSupportInputs=support, linuxSupportDelta=support_delta,
        acceptedMacCases=len(mac_ids), singleCleanMacInvocation=True, separateTestStderr=True), []


def validate_fresh_delta(before, after, data, candidate):
    if len(before) != 1164 or len(after) != 1170 or set(after) - set(before) != FRESH_ADDED or set(before) - set(after):
        raise RuntimeError('fresh wiring source inventory differs')
    changed = {p for p in before if before[p] != after[p]}
    if len(changed) != 27 or changed != set(data['modified']):
        raise RuntimeError('fresh wiring modified paths differ')
    if any(data['modified'][p] != dict(beforeSHA256=before[p], afterSHA256=after[p]) for p in changed):
        raise RuntimeError('fresh wiring delta hashes differ')
    if data['added'] != {p:after[p] for p in FRESH_ADDED}:
        raise RuntimeError('fresh wiring additions differ')
    preimages = data['preimages']
    if len(preimages) != 27 or {v['sourcePath'] for v in preimages} != changed:
        raise RuntimeError('fresh wiring preimage inventory differs')
    if any(row['sha256'] != before[row['sourcePath']] for row in preimages):
        raise RuntimeError('fresh wiring prior preimage differs')
    if len(candidate) != 38 or any(candidate.get(p) != after[p] for p in changed | FRESH_ADDED):
        raise RuntimeError('fresh wiring reviewed candidate differs')


def fixture_portability_basis(data, baseline, candidate, accepted_cases):
    expected = {
        'receipt': '780a5765e1d419230cb966a292c0fab57b4199710ec049b68cba1307ea51962f',
        'review': '6273dab9058ba686ec198495e8cc62d14ded13bfb5be2c6c6e50098e107380b3',
        'candidate': 'd99916416de63cf6522bedaa2cf4cfc69e9f2a5826864fc75a77b5e27daaaf45',
        'baselineCandidate': '052c9219cbdd9406ecfdcf57332a635d984eb663293d670e0ba758f0a6e3366e',
    }
    paths = {}
    for key, digest in expected.items():
        if data[key]['sha256'] != digest:
            raise RuntimeError('fixture portability authority differs: '+key)
        paths[key] = checked_reference(data[key])
    receipt = json.loads(paths['receipt'].read_text())
    references = receipt['references']
    if isinstance(references, dict):
        references = [dict(row,path=path) for path,row in references.items()]
    refs = {row['path']:row['sha256'] for row in references}
    for row in references:
        digest_reference(row)
    for key in ('candidate','compiledManifest','status','log'):
        if refs.get(data[key]['path']) != data[key]['sha256']:
            raise RuntimeError('fixture portability runtime reference differs: '+key)
    fixture = json.loads(paths['candidate'].read_text())
    baseline_fixture = json.loads(paths['baselineCandidate'].read_text())
    owned = {'Tests/TractandaServerTests/SharedDaemonTests.swift',
        'Tests/TractandaCoreTests/DocumentJobCoordinatorTests.swift',
        'Tests/TractandaMCPTests/DocumentJobIntegrationTests.swift'}
    harness = {'work/shared-authority-20261015/run-fixture-native.py',
        'work/shared-authority-20261015/fixture-proof-guard.py',
        'outputs/verification/cluster-2026-10-17/fixture-root-proof-faults.py'}
    if set(fixture['files']) != owned | harness or set(baseline_fixture['files']) != owned or set(baseline_fixture['preimages']) != owned:
        raise RuntimeError('fixture portability owned paths differ')
    for path,digest in fixture['files'].items():
        digest_reference(dict(path=path,sha256=digest))
    before = {row['path']:row['sha256'] for row in baseline}
    current = json.loads(checked_reference(data['compiledManifest']).read_text())['files']
    after = {row['path']:row['sha256'] for row in current}
    if len(current) != 1170 or set(before) != set(after) or {p for p in before if before[p] != after[p]} != owned:
        raise RuntimeError('fixture portability exact source delta differs')
    for path in owned:
        preimage = baseline_fixture['preimages'][path]
        if preimage['sha256'] != before[path] or fixture['files'][path] != after[path] or candidate[path] != before[path]:
            raise RuntimeError('fixture portability preimage/current hash differs')
        digest_reference(preimage)
    cases = sorted(case for case in accepted_cases if '.DocumentJobCoordinatorTests.' in case or '.DocumentJobIntegrationTests.' in case or ('.SharedDaemonTests.' in case and not case.endswith('testRebuildNoProgressConfigurationRejectsInvalidIntervals')))
    if len(cases) != 11:
        raise RuntimeError('fixture portability expected case set differs')
    verify_mac_cases(json.loads(checked_reference(data['status']).read_text()),
        checked_reference(data['log']).read_text(), cases, multiple_bundles=True)
    source_hashes = {path:fixture['files'][path] for path in owned}
    return current, dict(candidate,**source_hashes), dict(receiptSHA256=expected['receipt'],
        reviewSHA256=expected['review'], candidateSHA256=expected['candidate'],
        compiledManifestSHA256=data['compiledManifest']['sha256'], exactMacCases=cases,
        currentHashes=source_hashes, preimages=baseline_fixture['preimages'])


def fresh_store_basis(checkpoint, data):
    expected = {
        'priorStashReceipt': '4f788474f1f8179d60d49e613c32b870352f9568640904f7e3dc3cd236ee6a19',
        'currentMacReceipt': '4b11ef90336ee4cbd5db23c9a1ac31f9228ae2a2cb80d643b4c03758ac353a81',
        'currentMacReview': '8a5153d1ec38c2d39c7ccc0a419dbf3743e7d241133a7d2285b5ea6ee83c69f9',
    }
    paths = {}
    for key, digest in expected.items():
        if data[key]['sha256'] != digest:
            raise RuntimeError('fresh wiring checkpoint authority differs: ' + key)
        paths[key] = checked_reference(data[key])
    prior = json.loads(paths['priorStashReceipt'].read_text())
    stage_ref = prior['references'].get(data['priorStage']['path'])
    if prior['result'] != 'PASS' or prior['sourceInputs'] != 1164 or stage_ref != {k:v for k,v in data['priorStage'].items() if k != 'path'}:
        raise RuntimeError('fresh wiring prior accepted stage differs')
    stage = json.loads(checked_reference(data['priorStage']).read_text())
    if stage['macInputs'] != 1164:
        raise RuntimeError('fresh wiring prior inventory differs')
    old = [dict(row, path=row['path'].removeprefix('source/Tractanda/')) for row in stage['files'] if row['path'].startswith('source/Tractanda/')]
    receipt = json.loads(paths['currentMacReceipt'].read_text())
    for row in receipt['references']:
        digest_reference(row)
    verification = receipt['source_verification']
    if verification['generic_compiled_files'] != 1170 or verification['custom_files'] != 38 or verification['all_match_current'] is not True:
        raise RuntimeError('fresh wiring Mac source summary differs')
    for key, authority in [('macCompiledManifest','generic_manifest'), ('currentCandidate','custom_candidate')]:
        if {k:v for k,v in data[key].items() if k != 'bytes'} != verification[authority]:
            raise RuntimeError('fresh wiring Mac compilation authority differs')
    current = json.loads(checked_reference(data['macCompiledManifest']).read_text())['files']
    candidate = json.loads(checked_reference(data['currentCandidate']).read_text())['files']
    current, candidate, fixture_provenance = fixture_portability_basis(data['fixturePortability'], current, candidate, receipt['actual_test_ids'])
    before, after = [{v['path']:v['sha256'] for v in rows} for rows in (old,current)]
    if len(old) != 1164 or len(current) != 1170:
        raise RuntimeError('fresh wiring duplicate source input')
    validate_fresh_delta(before, after, data, candidate)
    for row in data['preimages']:
        checked_reference(row)
    for path, digest in candidate.items():
        digest_reference(dict(path=path,sha256=digest))
    extra = data['extraCompilationInputs']
    if len(extra) != 2 or {v['path'] for v in extra} != DEVELOPMENT_SWIFT or any(candidate[v['path']] != v['sha256'] for v in extra):
        raise RuntimeError('fresh wiring development compilation inputs differ')
    ancillary = data['ancillaryDevelopmentInputs']
    if len(ancillary) != 2 or {v['path'] for v in ancillary} != DEVELOPMENT_ANCILLARY or any(candidate[v['path']] != v['sha256'] for v in ancillary):
        raise RuntimeError('fresh wiring development ancillary inputs differ')
    cases = receipt['actual_test_ids']
    methods = json.loads(digest_reference(next(v for v in receipt['references'] if v['path'].endswith('fresh-store-wiring-expected-tests.json'))).read_text())
    if len(cases) != 73 or len(set(cases)) != 73 or sorted(v.split('.',1)[1] for v in cases) != sorted(methods):
        raise RuntimeError('fresh wiring accepted Mac case inventory differs')
    status_ref = next(v for v in receipt['references'] if v['path'].endswith('fresh-store-wiring-final-macos.status.json'))
    log_ref = next(v for v in receipt['references'] if v['path'].endswith('fresh-store-wiring-final-macos.log'))
    verify_mac_cases(json.loads(digest_reference(status_ref).read_text()), digest_reference(log_ref).read_text(), cases, multiple_bundles=True)
    excluded = {case for case in cases if '.SetupTests.' in case}
    ids = sorted(set(cases)-excluded)
    if len(excluded) != 3 or set(data['excluded']) != excluded or len(ids) != 70 or data['expectedIDs'] != ids:
        raise RuntimeError('fresh wiring portable exact selection differs')
    if any('Operator' in case or 'testStoppedDevelopmentStore' in case for case in ids):
        raise RuntimeError('real operator conversion must never be selected')
    return current + extra + ancillary, dict(kind='reviewed-fresh-store-wiring', checkpointSHA256=C.sha(checkpoint),
        sourceInputs=1174, genericMacInputs=1170, explicitDevelopmentInputs=extra, excludedDevelopmentAncillaries=ancillary,
        unchangedPriorInputs=1137, priorStashReceiptSHA256=expected['priorStashReceipt'],
        currentMacReceiptSHA256=expected['currentMacReceipt'], currentMacReviewSHA256=expected['currentMacReview'],
        currentMacManifestSHA256=fixture_provenance['compiledManifestSHA256'],
        baselineMac73ManifestSHA256=data['macCompiledManifest']['sha256'], fixturePortability=fixture_provenance,
        reviewedCandidateSHA256=data['currentCandidate']['sha256'], modified=data['modified'], added=data['added'],
        exactFocusedIDs=ids, excluded=data['excluded'], acceptedMacCases=73), []


def verify_cli_alias(root, binary=None):
    alias = root / 'source/Tractanda/.build'
    if not alias.is_symlink() or os.readlink(alias) != str(root/'scratch'):
        raise RuntimeError('fresh CLI fixture build alias differs')
    if binary is None:
        return
    cli = binary.parent/'tractanda'
    fixture_cli = alias/'debug/tractanda'
    if cli.is_symlink() or not cli.is_file() or fixture_cli.resolve(strict=True) != cli.resolve(strict=True):
        raise RuntimeError('fresh CLI fixture does not execute the new owned CLI')
    with cli.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            raise RuntimeError('new CLI executable is not ELF')
    return dict(fixtureCLIPath=str(fixture_cli), resolvedCLIPath=str(cli), bytes=cli.stat().st_size,
                sha256=C.sha(cli), ELF=True, aliasTarget=os.readlink(alias))


def account_general_fixture_tmp(root, fixtures, sample):
    general_tmp = root/'tmp'
    info = general_tmp.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700 or info.st_dev != fixtures.stat().st_dev:
        raise RuntimeError('general temporary fixture parent differs')
    additional = C.GATE.allocated_tree(general_tmp)
    aggregate = sample['fixtureAllocated'] + additional
    if aggregate > FIXTURE_CAP:
        raise RuntimeError('aggregate fixture and temporary cap exceeded')
    return dict(sample,generalTemporaryAllocated=additional,fixtureAllocated=aggregate)


def fixture_runtime_seen(output, expected_ids):
    names = {'.'.join(case.split('.')[-2:]) for case in expected_ids}
    events = re.findall(r"Test Case '([^']+)' started",output)
    return any('.'.join(event.split('.')[-2:]) in names for event in events)


def inspect_fixture_proofs(root, fixtures, expected_ids, complete=False, not_before_ns=0):
    proof = root/'fixture-proof'
    if fixtures != root/'fixtures':
        raise RuntimeError('fixture parent is outside the exact native root')
    for directory in (fixtures,proof):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.getuid() or directory.resolve(strict=True) != directory:
            raise RuntimeError('guarded fixture proof parent is unsafe')
    if fixtures.stat().st_dev != proof.stat().st_dev:
        raise RuntimeError('fixture proof parent filesystem differs')
    expected = {'.'.join(case.split('.')[-2:]) for case in expected_ids}
    if not 0 < len(expected) <= 512 or len(expected_ids) != len(expected):
        raise RuntimeError('fixture proof expected case inventory differs')
    facts = []
    descriptor = os.open(proof,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        entries = []
        for entry in proof.iterdir():
            entries.append(entry)
            if len(entries) > len(expected):
                raise RuntimeError('fixture proof record cap exceeded')
        for path in entries:
            fd = os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK,dir_fd=descriptor)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid() or info.st_nlink != 1 or not 0 < info.st_size <= 2048 or info.st_mtime_ns < not_before_ns:
                    raise RuntimeError('fixture proof file ownership/mode/size/freshness differs')
                payload = os.read(fd,2049)
                if len(payload) != info.st_size:
                    raise RuntimeError('fixture proof file changed during inspection')
            finally:
                os.close(fd)
            def unique_object(pairs):
                value = {}
                for key,item in pairs:
                    if key in value:
                        raise RuntimeError('fixture proof duplicate JSON key')
                    value[key] = item
                return value
            row = json.loads(payload.decode('utf-8'),object_pairs_hook=unique_object)
            fields = {'profile','source','test','root','expectedRoot','proofRoot','uid','pid','phase'}
            if not isinstance(row,dict) or set(row) != fields or row['profile'] != 'tractanda.fixture-root-proof.v1' or row['phase'] != 'created':
                raise RuntimeError('fixture proof schema differs')
            if type(row['uid']) is not int or row['uid'] != os.getuid() or type(row['pid']) is not int or row['pid'] <= 0:
                raise RuntimeError('fixture proof actor differs')
            if not all(isinstance(row[key],str) for key in ('source','test','root','expectedRoot','proofRoot')) or len(row['test'].encode()) > 256:
                raise RuntimeError('fixture proof text differs')
            name = row['test']
            if name.startswith('-[') and name.endswith(']'):
                name = name[2:-1].replace(' ','.')
            normalized = '.'.join(name.split('.')[-2:])
            if normalized not in expected or normalized.split('.')[0] != row['source']:
                raise RuntimeError('fixture proof method differs')
            location = Path(row['root'])
            if row['expectedRoot'] != str(fixtures) or row['proofRoot'] != str(proof) or not location.is_absolute() or str(location) != row['root'] or location.parent != fixtures or location.resolve(strict=False) != location:
                raise RuntimeError('fixture proof escaped exact guarded root')
            source = FIXTURE_SOURCES.get(row['source'])
            prefix = source[1] if source is not None else None
            if prefix is None or not re.fullmatch(prefix+r'[A-Fa-f0-9]{7}',location.name) or path.name != row['source']+'-'+location.name+'.json':
                raise RuntimeError('fixture proof filename differs')
            try:
                actual = location.lstat()
            except FileNotFoundError:
                actual = None  # Completed test cleanup may already have removed the created fixture.
            if actual is not None and (not stat.S_ISDIR(actual.st_mode) or stat.S_IMODE(actual.st_mode) != 0o700 or actual.st_uid != os.getuid()):
                raise RuntimeError('live fixture root ownership/type/mode differs')
            fact = dict(method=normalized,root=row['root'],pid=row['pid'])
            if complete:
                fact.update(fileName=path.name,rawUTF8=payload.decode('utf-8'),sha256=hashlib.sha256(payload).hexdigest(),
                    bytes=info.st_size,mode=stat.S_IMODE(info.st_mode),uid=info.st_uid,mtime_ns=info.st_mtime_ns)
            facts.append(fact)
    finally:
        os.close(descriptor)
    temporary = []
    for path in fixtures.glob('.fixture-proof-*.tmp'):
        info = path.lstat()
        if not re.fullmatch(r'\.fixture-proof-[0-9A-Fa-f-]{36}\.tmp',path.name) or not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid() or info.st_nlink != 1 or not 0 <= info.st_size <= 2048:
            raise RuntimeError('fixture proof temporary file is unsafe')
        temporary.append(str(path))
        if len(temporary) > 1:
            raise RuntimeError('fixture proof temporary count exceeded')
    if complete and temporary:
        raise RuntimeError('fixture proof unpublished temporary remains')
    methods = [row['method'] for row in facts]
    if len(set(methods)) != len(methods) or (complete and set(methods) != expected):
        raise RuntimeError('fixture proof missing or duplicate actual methods')
    remaining = []
    if complete:
        roots = {row['root'] for row in facts}
        for path in fixtures.iterdir():
            if len(remaining) >= len(expected):
                raise RuntimeError('fixture final root inventory cap exceeded')
            info = path.lstat()
            if str(path) not in roots or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700 or path.resolve(strict=True) != path:
                raise RuntimeError('fixture final root contains unknown or unsafe entry')
            remaining.append(str(path))
    return dict(records=len(facts),expected=len(expected),complete=set(methods)==expected,temporary=temporary,
                remainingFixtureRoots=sorted(remaining),facts=sorted(facts,key=lambda row:row['method']))


def mirror_inputs(pins, prefix='mirrors/'):
    if not pins or len(pins) > 16 or len({p['identity'] for p in pins}) != len(pins):
        raise RuntimeError('offline pin inventory differs')
    safe_member(prefix.rstrip('/'))
    origins = {}
    for pin in pins:
        identity, state = pin['identity'], pin['state']
        if not re.fullmatch(r'[a-z0-9-]+', identity) or not re.fullmatch(r'[0-9a-f]{40}', state['revision']) or not re.fullmatch(r'[0-9.]+', state['version']):
            raise RuntimeError('noncanonical dependency pin')
        mirror = REPO / 'work/peer-transport-20261015/mirrors' / (identity + '.git')
        subprocess.run(['git', '-C', str(mirror), 'cat-file', '-e', state['revision'] + '^{commit}'], check=True, capture_output=True, timeout=15)
        for p in (mirror / 'objects').rglob('*'):
            rel = str(p.relative_to(mirror))
            if p.is_symlink():
                raise RuntimeError('offline mirror symlink')
            if p.is_file() and re.fullmatch(r'objects/(?:[0-9a-f]{2}/[0-9a-f]{38}|pack/pack-[0-9a-f]{40}\.(?:pack|idx|rev))', rel):
                origins[prefix + identity + '.git/' + rel] = p
        target = prefix + identity + '.git/'
        origins[target + 'HEAD'] = b'ref: refs/heads/validation\n'
        origins[target + 'refs/heads/validation'] = (state['revision'] + '\n').encode()
        origins[target + 'refs/tags/' + state['version']] = (state['revision'] + '\n').encode()
        origins[target + 'config'] = b'[core]\n\trepositoryformatversion = 0\n\tbare = true\n'
        if (mirror / 'shallow').exists():
            origins[target + 'shallow'] = mirror / 'shallow'
    return origins


def local_inputs(checkpoint=None):
    mac, provenance, extra = source_basis(checkpoint)
    receipt = C.checked_json(REPO / C.MAC_RECEIPT, C.MAC_RECEIPT_SHA)
    owned = C.checked_json(REPO / C.OWNED, C.OWNED_SHA)['files']
    if len(mac) != provenance.get('sourceInputs', 1160) or len([v for v in owned if v['path'].endswith('.swift')]) != 40:
        raise RuntimeError('unexpected Mac freeze inventory')
    mac_map = {v['path']: v['sha256'] for v in C.checked_json(REPO / C.MAC_SOURCE, C.MAC_SOURCE_SHA)['files']}
    if any(mac_map.get(v['path']) != v['sha256'] for v in owned if v['path'].endswith('.swift')):
        raise RuntimeError('owned Swift freeze differs')
    origins = {}
    for row in mac:
        p = REPO / row['path']
        if p.is_symlink() or C.sha(p) != row['sha256']:
            raise RuntimeError('current Mac input drift: ' + row['path'])
        origins['source/Tractanda/' + row['path']] = p
    if sum(p.stat().st_size for p in origins.values()) > SOURCE_CAP:
        raise RuntimeError('source exceeds 128MiB cap')
    for name in SUPPORT:
        origins['support/' + name] = REPO / 'scripts' / name
    pins = json.loads((REPO / 'Package.resolved').read_text())['pins']
    if len(pins) != 9:
        raise RuntimeError('expected nine offline pins')
    origins.update(mirror_inputs(pins))
    packages = provenance.get('packageTests', [])
    for scope in packages:
        origins.update(mirror_inputs(scope['pins'], scope['mirrorPrefix']))
    records = []
    for name, origin in sorted(origins.items()):
        safe_member(name)
        size = len(origin) if isinstance(origin, bytes) else origin.stat().st_size
        digest = hashlib.sha256(origin).hexdigest() if isinstance(origin, bytes) else C.sha(origin)
        records.append(dict(path=name, bytes=size, sha256=digest))
    for path, digest in provenance.get('linuxSupportInputs', {}).items():
        row = next((row for row in records if row['path'] == 'support/' + Path(path).name), None)
        if row is None or row['sha256'] != digest:
            raise RuntimeError('reviewed Linux support changed before staging')
    if sum(v['bytes'] for v in records) > 160 * 1024**2:
        raise RuntimeError('transfer exceeds estimated 160MiB input bound')
    ids, expression = C.checked_selection(receipt)
    if provenance.get('kind') in ('reviewed-enrollment-target', 'reviewed-fresh-store-wiring', 'reviewed-source-approval', 'reviewed-linux-package'):
        ids = provenance['exactFocusedIDs']
        expression = '^(?:' + '|'.join(re.escape(v.rsplit('.', 1)[0]) + '/' + v.rsplit('.', 1)[1] for v in ids) + ')$'
    elif extra:
        ids = sorted(ids + extra)
        expected_count = provenance.get('expectedStashCases', 125)
        if len(ids) != expected_count or len(set(ids)) != expected_count:
            raise RuntimeError('expanded selection must contain exactly ' + str(expected_count) + ' distinct cases')
        expression = '^(?:' + '|'.join(re.escape(v.rsplit('.', 1)[0]) + '/' + v.rsplit('.', 1)[1] for v in ids) + ')$'
    return origins, dict(profile='tractanda.stash-cluster.v1', files=records, pins=pins, ids=ids,
        testFilter=expression, packageTests=packages, sourceProvenance=provenance, macInputs=len(mac), baselineOwnedSwift=40)


class ChildCommands:
    """Keep compiler/test children from consuming the supervisor's lease stdin."""
    def __getattr__(self, name):
        return getattr(subprocess, name)

    def Popen(self, *args, **kwargs):
        return subprocess.Popen(*args, **dict(kwargs, stdin=subprocess.DEVNULL))


def resolve_toolchain():
    entry = shutil.which('swift')
    if not entry:
        raise RuntimeError('Swift command is absent')
    entry = Path(entry)
    if entry.resolve().name == 'swiftly':
        # Without a selector, this help-documented option only reads current selection.
        value = json.loads(subprocess.check_output(['swiftly', 'use', '--print-location', '--format', 'json'], text=True, timeout=15))
        selected = Path(value['path'])
        if not selected.is_absolute() or '..' in selected.parts:
            raise RuntimeError('unsafe selected toolchain location')
        tools = selected / 'usr/bin'
    else:
        tools = entry.parent
    for name in ('swift', 'clang', 'swift-frontend'):
        p = tools / name
        if not p.is_file() or p.resolve().name == 'swiftly':
            raise RuntimeError('selected toolchain is absent or still a manager shim: ' + str(p))
    return tools  # Preserve named entries: argv[0] selects Swift/clang driver mode.


def toolchain_versions(tools, environment):
    return {name: subprocess.check_output([str(tools / name), '--version'], env=environment, text=True, timeout=15)
            for name in ('swift', 'clang')}


def environment_fingerprint(tools, environment):
    names = ['libc6', 'libpam0g', 'libpam0g-dev', 'libsqlite3-0', 'libuuid1']
    packages = subprocess.check_output(['dpkg-query', '-W', *names], text=True, timeout=15)
    versions = toolchain_versions(tools, environment)
    paths = [Path('/usr/include/security/pam_appl.h'), Path('/usr/lib/x86_64-linux-gnu/libpam.so'),
             Path('/usr/lib/x86_64-linux-gnu/libsqlite3.so'), Path('/usr/lib/x86_64-linux-gnu/libuuid.so')]
    paths += sorted(Path('/usr/include/security').glob('_pam*.h'))
    paths.extend(tools / name for name in ('swift', 'swift-frontend', 'clang'))
    rows = []
    for p in paths:
        actual = p.resolve(strict=True)
        rows.append(dict(path=str(p), target=str(actual), bytes=actual.stat().st_size, sha256=C.sha(actual)))
    return dict(**versions, packages=packages, files=rows, concreteBin=str(tools), privateHome=environment['HOME'])


# This bootstrap creates only the exact fresh private root after an explicit run invocation.
# No archive extraction API is allowed to create links or choose paths outside it.
BOOTSTRAP = r'''
import hashlib,json,os,pathlib,pwd,re,shutil,subprocess,sys,tarfile

def need(ok,message):
 if not ok:raise RuntimeError(message)
root=pathlib.Path(sys.argv[1]);label=sys.argv[2];expected=sys.argv[3];input_bytes=int(sys.argv[4])
need(0<input_bytes<=160*1024**2,'invalid transfer estimate')
need(bool(re.fullmatch(r'stash-cluster-b2-20261016-[0-9a-f]{8}',label)),'unsafe label')
home=pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
need(home.is_absolute() and home.resolve()==home and not home.is_symlink() and home.is_dir() and home.stat().st_uid==1001,'unexpected account home')
need(root==home/'.cache'/('tractanda-'+label),'unsafe root')
need(os.getuid()==1001 and os.getgid()==1001 and not root.parent.is_symlink(),'unexpected identity/parent')
need(root.parent.resolve()==root.parent and root.parent.stat().st_uid==1001,'unexpected cache owner')
f=os.statvfs(root.parent);need(f.f_frsize>0 and f.f_bavail>=0 and f.f_bavail*f.f_frsize>=12*1024**3,'remote preflight space')
estimate=input_bytes+16*1024**2+13*1024**3//4+64*1024**2+128*1024**2
need(estimate+256*1024**2<=4*1024**3 and f.f_bavail*f.f_frsize-estimate>=10*1024**3,'remote cold-work estimate rejected')
admission={'location':str(root.parent),'available':f.f_bavail*f.f_frsize,'inputBytes':input_bytes,'allocatedEstimate':estimate,'runtimeAllowance':256*1024**2,'cap':4*1024**3,'reserve':10*1024**3}
need(int(next(x.split()[1] for x in pathlib.Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:')))*1024>=6*1024**3,'remote RAM preflight')
need(pathlib.Path('/usr/include/security/pam_appl.h').is_file() and pathlib.Path('/usr/lib/x86_64-linux-gnu/libpam.so').exists(),'installed PAM development support absent')
unit=subprocess.run(['systemctl','--user','show',label+'.service','-p','LoadState','--value'],capture_output=True,text=True,timeout=10)
need(unit.returncode in (0,1) and unit.stdout.strip()=='not-found','unit name unavailable or already exists')
os.umask(0o077);root.mkdir(mode=0o700,exist_ok=False)
total=0;a=tarfile.open(fileobj=sys.stdin.buffer,mode='r|gz')
for m in a:
 p=pathlib.PurePosixPath(m.name)
 need(not p.is_absolute() and '..' not in p.parts and str(p)==m.name and '\\' not in m.name and m.isfile(),'unsafe archive member')
 need(0<=m.size<=128*1024**2,'oversized archive member')
 total+=m.size;need(total<=input_bytes<=160*1024**2,'transfer estimate exceeded')
 f=os.statvfs(root);need(f.f_frsize>0 and f.f_bavail>=0 and f.f_bavail*f.f_frsize-m.size>=10*1024**3,'remote staging reserve')
 target=root/m.name;target.parent.mkdir(parents=True,exist_ok=True)
 with target.open('xb') as out:
  stream=a.extractfile(m);remaining=m.size
  while remaining:
   chunk=stream.read(min(1024*1024,remaining));need(bool(chunk),'truncated archive')
   out.write(chunk);remaining-=len(chunk)
 target.chmod(0o444)
manifest=root/'stage.json';need(hashlib.sha256(manifest.read_bytes()).hexdigest()==expected,'manifest digest mismatch')
d=json.loads(manifest.read_text())
if d.get('sourceProvenance',{}).get('kind')=='reviewed-fresh-store-wiring':
 os.symlink(str(root/'scratch'),root/'source/Tractanda/.build')
if d.get('sourceProvenance',{}).get('kind')=='reviewed-fresh-store-wiring' or d.get('sourceProvenance',{}).get('fixtureProofIDs'):
 (root/'fixture-proof').mkdir(mode=0o700)
for row in d['files']:
 p=root/row['path'];need(p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256'],'staged input mismatch')
for name in ['logs','scratch','cache','config','security','modules','fixtures','home','tmp','source/Tractanda/.swiftpm']:
 (root/name).mkdir(mode=0o700,parents=True,exist_ok=True)
packages=d.get('packageTests',[]);need(len(packages)<=1,'nested package scope count differs')
for scope in packages:
 need(scope['name']=='peer-tls' and scope['packagePath']=='Packages/TractandaPeerTLS','unexpected nested package metadata root')
 (root/'source/Tractanda'/scope['packagePath']/'.swiftpm').mkdir(mode=0o700,exist_ok=False)
for name in ['source/Tractanda','mirrors','support']:
 for directory,dirs,files in os.walk(root/name,topdown=False):
  q=pathlib.Path(directory)
  if '.swiftpm' not in q.parts:q.chmod(0o555)
print(json.dumps({'root':str(root),'bytes':total,'manifestSHA256':expected,'staged':True,'PATH':os.environ.get('PATH'),'swiftPath':shutil.which('swift'),'coldAdmission':admission}))
'''


class Lease:
    def __init__(self, session, source_sha, stream=None):
        self.session, self.source_sha = session, source_sha
        self.last, self.error = time.monotonic(), 'first lease has not arrived'
        self.stream = stream if stream is not None else sys.stdin

    def accept(self, line):
        value = json.loads(line)
        if value != dict(session=self.session, sourceSHA256=self.source_sha):
            raise RuntimeError('lease source/session mismatch')
        self.last, self.error = time.monotonic(), None

    def watch(self):
        try:
            while True:
                line = self.stream.readline(512)
                if not line:
                    break
                if not line.endswith('\n'):
                    raise RuntimeError('oversized or incomplete lease')
                self.accept(line)
            self.error = 'SSH lease EOF'
        except BaseException as error:
            self.error = str(error)

    def check(self):
        if self.error or time.monotonic() - self.last > LEASE_SECONDS:
            raise RuntimeError('remote lease rejected: ' + str(self.error or 'stale'))


def verify_cgroup(label):
    relative = Path('/proc/self/cgroup').read_text().strip().split('::', 1)[1]
    if '..' in Path(relative).parts or not relative.endswith('/' + label + '.service') or '/user-1001.slice/' not in relative:
        raise RuntimeError('worker is outside exact owned user cgroup')
    p = Path('/sys/fs/cgroup') / relative.lstrip('/')
    actual = {name: (p / name).read_text().strip() for name in ('memory.max', 'memory.swap.max', 'cpu.max', 'pids.max')}
    quota, period = actual['cpu.max'].split()
    if actual['memory.max'] != str(3 * 1024**3) or actual['memory.swap.max'] != '0' or quota == 'max' or int(quota) > 2 * int(period) or actual['pids.max'] != '128':
        raise RuntimeError('transient service limits differ: ' + json.dumps(actual))
    affinity = sorted(os.sched_getaffinity(0))
    if len(affinity) != 2 or os.getpriority(os.PRIO_PROCESS, 0) < 10:
        raise RuntimeError('CPU affinity/priority bound missing')
    return dict(path=str(p), limits=actual, affinity=affinity, nice=os.getpriority(os.PRIO_PROCESS, 0))


def filesystem_kind(path):
    candidates = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        before, after = line.split(' - ', 1)
        mount = Path(before.split()[4])
        if path.is_relative_to(mount):
            candidates.append((len(mount.parts), after.split()[0]))
    if not candidates:
        raise RuntimeError('fixture filesystem type unavailable')
    return max(candidates)[1]


def seconds(value):
    units = {'us': 0.000001, 'ms': 0.001, 's': 1, 'min': 60, 'h': 3600, 'd': 86400, 'w': 604800}
    tokens = re.findall(r'(\d+(?:\.\d+)?)(min|ms|us|w|d|h|s)', value)
    if not tokens or re.sub(r'(\d+(?:\.\d+)?)(min|ms|us|w|d|h|s)\s*', '', value):
        raise RuntimeError('unknown systemd timespan: ' + value)
    return sum(float(number) * units[unit] for number, unit in tokens)


def verify_unit(root, label, runtime_seconds):
    names = ['RuntimeMaxUSec', 'TimeoutStopUSec', 'KillMode', 'OOMPolicy', 'MainPID', 'User', 'Group', 'Transient', 'ExecStart']
    output = subprocess.check_output(['systemctl', '--user', 'show', label + '.service', *['--property=' + v for v in names]], text=True, timeout=10)
    values = dict(line.split('=', 1) for line in output.splitlines() if '=' in line)
    if seconds(values.get('RuntimeMaxUSec', '')) != runtime_seconds or seconds(values.get('TimeoutStopUSec', '')) != 15 or \
            values.get('KillMode') != 'control-group' or values.get('OOMPolicy') != 'kill' or values.get('Transient') != 'yes' or \
            values.get('MainPID') != str(os.getpid()) or values.get('User') not in ('', 'rcfa', '1001') or \
            values.get('Group') not in ('', 'rcfa', '1001') or str(root / 'support/verify-stash-cluster.py') not in values.get('ExecStart', ''):
        raise RuntimeError('actual transient lifecycle/identity properties differ: ' + json.dumps(values))
    return dict(raw=values, runtimeSeconds=runtime_seconds, stopSeconds=15, uid=os.getuid(), gid=os.getgid())


def configure_and_test(toolchain, common, descriptor, root, environment,
                       command_timeout_seconds=DEFAULT_TIMEOUT_SECONDS):
    for pin in descriptor['pins']:
        mirror = root / 'mirrors' / (pin['identity'] + '.git')
        C.run(['git', '-C', str(mirror), 'cat-file', '-e', pin['state']['revision'] + '^{commit}'], 'pin-' + pin['identity'], environment, 30)
        C.run([str(toolchain / 'swift'), 'package', *common, 'config', 'set-mirror', '--original', pin['location'], '--mirror', mirror.as_uri()], 'mirror-' + pin['identity'], environment, 30)
    packages = descriptor.get('packageTests', [])
    scopes = [dict(name='root', ids=descriptor['ids'], label='tests', state='pending', runtimePassed=False)]
    scopes += [dict(name=p['name'], ids=p['ids'], label='package-'+p['name']+'-tests', state='pending', runtimePassed=False) for p in packages]
    C.GATE.save(C.LOGS/'test-scopes.json', dict(scopes=scopes))
    for index, scope in enumerate(scopes):
        scope.update(state='running', phase='tests')
        C.GATE.save(C.LOGS/'test-scopes.json', dict(scopes=scopes))
        try:
            if index == 0:
                arguments, env, expression = common, environment, descriptor['testFilter']
            else:
                package = packages[index-1]
                if package['name'] != 'peer-tls' or package['packagePath'] != 'Packages/TractandaPeerTLS':
                    raise RuntimeError('unexpected native nested package scope')
                scope['coldAdmission'] = admit_cold_work(C.capacity(), PACKAGE_OUTPUT_ESTIMATE)
                work = root/'package-tests'/package['name']
                work.mkdir(mode=0o700, parents=True, exist_ok=False)
                arguments = ['--package-path', str(root/'source/Tractanda'/package['packagePath']), '--disable-sandbox']
                for kind in ('scratch', 'cache', 'config', 'security'):
                    arguments += ['--'+kind+'-path', str(work/kind)]
                mirror_rows = []
                for pin in package['pins']:
                    mirror = root/package['mirrorPrefix']/(pin['identity']+'.git')
                    C.run(['git', '-C', str(mirror), 'cat-file', '-e', pin['state']['revision']+'^{commit}'],
                          'package-pin-'+pin['identity'], environment, 30)
                    mirror_rows.append(dict(original=pin['location'], mirror=mirror.as_uri()))
                override = C.LOGS/'package-peer-tls-mirrors.json'
                C.GATE.save(override, dict(version=1, object=mirror_rows))
                env = dict(environment, SWIFTPM_MIRROR_CONFIG=str(override),
                           CLANG_MODULE_CACHE_PATH=str(work/'modules'), SWIFTPM_MODULECACHE_OVERRIDE=str(work/'modules'))
                expression = package['testFilter']
            C.run([str(toolchain/'swift'), 'test', *arguments, '--build-system', 'native', '--enable-index-store',
                   '--force-resolved-versions', '--jobs', '1', '--filter', expression], scope['label'], env,
                  command_timeout_seconds,
                  separate_stderr=descriptor.get('sourceProvenance', {}).get('separateTestStderr', False))
            status = json.loads((C.LOGS/(scope['label']+'.status.json')).read_text())
            C.verify_results(status, (C.LOGS/(scope['label']+'.log')).read_text(), scope['ids'])
            scope.update(state='passed', runtimePassed=True, tests=len(scope['ids']), seconds=status['seconds'])
            if index:
                scope['phase'] = 'postchecks'
                scope['native'] = package_postchecks(work, environment)
            scope['phase'] = 'complete'
        except BaseException as error:
            scope.update(state='failed', failure=str(error))
            raise
        finally:
            C.GATE.save(C.LOGS/'test-scopes.json', dict(scopes=scopes))
    return scopes


def package_postchecks(work, environment):
    binaries = [p for p in (work/'scratch').rglob('TractandaPeerTLSPackageTests.xctest') if p.is_file() and not p.is_symlink()]
    if len(binaries) != 1:
        raise RuntimeError('nested package test executable is not one actual ELF')
    binary = binaries[0]
    with binary.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            raise RuntimeError('nested package test executable is not ELF')
    digest = C.sha(binary)
    C.run(['nm', '-g', str(binary)], 'package-peer-tls-symbols', environment, 60)
    symbols = (C.LOGS/'package-peer-tls-symbols.log').read_text()
    defined = sum(1 for line in symbols.splitlines() if len(v := line.split()) >= 3 and v[-2].upper() != 'U' and v[-1].startswith('CNIOBoringSSL_'))
    if not defined or C.sha(binary) != digest:
        raise RuntimeError('nested package TLS symbols absent or tested ELF changed')
    C.run(['ldd', str(binary)], 'package-peer-tls-libraries', environment, 30)
    if 'not found' in (C.LOGS/'package-peer-tls-libraries.log').read_text():
        raise RuntimeError('nested package runtime library unresolved')
    return dict(binary=str(binary), binarySHA256=digest, definedBoringSSLSymbols=defined, runtimeLibrariesResolved=True)


def loopback_probe():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.settimeout(3)
        server.bind(('127.0.0.1', 0)); server.listen(1)
        with socket.create_connection(server.getsockname(), timeout=3) as client:
            with server.accept()[0] as receiver:
                receiver.settimeout(3); client.sendall(b'loopback')
                received = b''
                while len(received) < 8:
                    chunk = receiver.recv(8-len(received))
                    if not chunk:
                        break
                    received += chunk
                if received != b'loopback':
                    raise RuntimeError('IPv4 loopback probe payload differs')
        return dict(address='127.0.0.1', family='IPv4', success=True)

def native(root, label, session, manifest_sha, timeout_seconds=DEFAULT_TIMEOUT_SECONDS,
           command_timeout_seconds=DEFAULT_TIMEOUT_SECONDS):
    command_timeout_seconds = effective_command_timeout(timeout_seconds, command_timeout_seconds)
    operation_deadline = time.monotonic() + timeout_seconds
    account_home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    if root != remote_root(account_home, label) or root.is_symlink() or root.stat().st_uid != REMOTE_UID or stat.S_IMODE(root.stat().st_mode) != 0o700:
        raise RuntimeError('unexpected private native root')
    if (os.getuid(), os.getgid(), platform.machine()) != (REMOTE_UID, REMOTE_GID, 'x86_64'):
        raise RuntimeError('native identity/architecture mismatch')
    descriptor = C.checked_json(root / 'stage.json', manifest_sha)
    verify_files(root, descriptor['files'])
    if descriptor['sourceProvenance']['kind'] == 'reviewed-fresh-store-wiring':
        verify_cli_alias(root)
    lease = Lease(session, manifest_sha)
    threading.Thread(target=lease.watch, daemon=True).start()
    deadline = time.monotonic() + 3
    while lease.error and time.monotonic() < deadline:
        time.sleep(0.05)
    cgroup = verify_cgroup(label)
    budgets = timeout_budgets(timeout_seconds)
    unit = verify_unit(root, label, budgets['unitRuntimeSeconds'])
    logs, source, fixtures = root / 'logs', root / 'source/Tractanda', root / 'fixtures'
    fixture_kind = filesystem_kind(fixtures)
    if fixture_kind in ('tmpfs', 'ramfs', 'hugetlbfs'):
        raise RuntimeError('fixture path is on a memory filesystem')
    C.LOGS, C.REPO, C.FIXTURES = logs, source, fixtures
    proof_not_before_ns = (root/'stage.json').stat().st_mtime_ns
    proof_runtime_started = None
    expected_proof_ids = fixture_proof_ids(descriptor['sourceProvenance'])
    def guard(initial=False):
        nonlocal proof_runtime_started
        if time.monotonic() >= operation_deadline:
            raise RuntimeError('whole native test operation deadline exceeded')
        lease.check()
        sample = capacity(root, fixtures, initial)
        if expected_proof_ids:
            sample = account_general_fixture_tmp(root,fixtures,sample)
            sample['fixtureProof'] = inspect_fixture_proofs(root,fixtures,expected_proof_ids,not_before_ns=proof_not_before_ns)
            test_log = logs/'tests.log'
            if proof_runtime_started is None and test_log.exists() and fixture_runtime_seen(test_log.read_text(),expected_proof_ids):
                proof_runtime_started = time.monotonic()
            if proof_runtime_started is not None and not sample['fixtureProof']['records'] and time.monotonic()-proof_runtime_started > 10:
                raise RuntimeError('affected XCTest fixture produced no proof within ten seconds')
        sample['cgroup'] = verify_cgroup(label)
        return sample
    C.capacity = guard
    C.subprocess = ChildCommands()
    cold_admission = admit_cold_work(guard(True))
    C.GATE.save(logs / 'cold-admission.json', cold_admission)
    toolchain = resolve_toolchain()
    environment = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL') if key in os.environ}
    environment.update(HOME=str(root / 'home'), XDG_CACHE_HOME=str(root / 'cache'), TMPDIR=str(fixtures),
        GIT_ALLOW_PROTOCOL='file', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0',
        CLANG_MODULE_CACHE_PATH=str(root / 'modules'), SWIFTPM_MODULECACHE_OVERRIDE=str(root / 'modules'))
    environment['PATH'] = str(toolchain) + ':/usr/bin:/bin'
    if expected_proof_ids:
        environment.update(TMPDIR=str(root/'tmp'), TRACTANDA_TEST_FIXTURE_ROOT=str(fixtures),
            TRACTANDA_TEST_FIXTURE_PROOF=str(root/'fixture-proof'), TRACTANDA_TEST_FIXTURE_GUARDED='1')
    def interrupted(signum, frame):
        raise InterruptedError('native worker received signal ' + str(signum))
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    result = dict(session=session, sourceSHA256=manifest_sha, running=True, testsRequested=len(descriptor['ids']),
                  packageTestsRequested={p['name']:len(p['ids']) for p in descriptor.get('packageTests', [])},
                  cgroup=cgroup, unit=unit, coldAdmission=cold_admission, timeoutBudgets=budgets,
                  commandTimeoutSeconds=command_timeout_seconds)
    C.GATE.save(logs / 'native.status.json', result)
    try:
        before = environment_fingerprint(toolchain, environment)
        C.GATE.save(logs / 'environment-before.json', before)
        C.GATE.save(logs / 'native-identity.json', dict(uid=os.getuid(), gid=os.getgid(), root=str(root),
            fixtures=str(fixtures), fixtureOwner=fixtures.stat().st_uid, fixtureAvailable=os.statvfs(fixtures).f_bavail * os.statvfs(fixtures).f_frsize,
            sameFilesystem=fixtures.stat().st_dev == root.stat().st_dev, filesystem=fixture_kind, nativeUUIDOverride=False, cgroup=cgroup))
        if fixtures.stat().st_dev != root.stat().st_dev or fixtures.stat().st_uid != 1001:
            raise RuntimeError('fixture filesystem/ownership differs')
        common = ['--package-path', str(source), '--disable-sandbox']
        for kind in ('scratch', 'cache', 'config', 'security'):
            common += ['--' + kind + '-path', str(root / kind)]
        C.run([str(toolchain / 'swift'), '--version'], 'toolchain', environment, 30)
        version = re.search(r'Swift version (\d+)\.(\d+)', (logs / 'toolchain.log').read_text())
        if not version or tuple(map(int, version.groups())) < (6, 4):
            raise RuntimeError('Swift toolchain does not meet project 6.4 baseline')
        if not Path('/usr/include/security/pam_appl.h').is_file() or not Path('/usr/lib/x86_64-linux-gnu/libpam.so').exists():
            raise RuntimeError('installed PAM development support absent')
        C.run(['dpkg-query', '-W', 'libc6', 'libpam0g', 'libpam0g-dev', 'libsqlite3-0', 'libuuid1'], 'system-libraries', environment, 30)
        if any('.PeerResponderLoopbackTests.' in case for case in descriptor['ids']):
            C.GATE.save(logs/'ipv4-loopback.json', loopback_probe())
        configure_and_test(toolchain, common, descriptor, root, environment, command_timeout_seconds)
        C.verify_results(json.loads((logs / 'tests.status.json').read_text()), (logs / 'tests.log').read_text(), descriptor['ids'])
        verify_files(root, descriptor['files'])
        C.checked_json(root / 'stage.json', manifest_sha)
        candidates = [p for p in (root / 'scratch').rglob('TractandaPackageTests.xctest') if p.is_file() and not p.is_symlink()]
        if len(candidates) != 1:
            raise RuntimeError('expected one actual combined Linux executable')
        binary = candidates[0]
        with binary.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                raise RuntimeError('test executable is not ELF')
        binary_sha = C.sha(binary)
        C.run(['nm', '-g', str(binary)], 'symbols', environment, 60)
        symbols = (logs / 'symbols.log').read_text()
        groups = C.GATE.combined_symbol_groups(symbols)
        tls = sorted({v[-1] for line in symbols.splitlines() if len(v := line.split()) >= 3 and v[-2].upper() != 'U' and 'TractandaPeerTLS' in v[-1] and ('TLSContext' in v[-1] or 'TLSSession' in v[-1])})
        if not tls or C.sha(binary) != binary_sha:
            raise RuntimeError('actual PeerTLS symbols absent or tested ELF changed')
        C.run(['ldd', str(binary)], 'runtime-libraries', environment, 30)
        if 'not found' in (logs / 'runtime-libraries.log').read_text():
            raise RuntimeError('runtime library unresolved')
        C.run([str(binary.parent / 'tractanda'), 'uuid-node'], 'native-uuid-node', environment, 30)
        after = environment_fingerprint(toolchain, environment)
        verify_unit(root, label, budgets['unitRuntimeSeconds'])
        C.GATE.save(logs / 'environment-after.json', after)
        if before != after:
            raise RuntimeError('toolchain/system dependencies changed during run')
        if descriptor['sourceProvenance']['kind'] == 'reviewed-fresh-store-wiring':
            result['actualFixtureCLI'] = verify_cli_alias(root, binary)
        if expected_proof_ids:
            result['actualFixtureProof'] = inspect_fixture_proofs(root,fixtures,expected_proof_ids,complete=True,not_before_ns=proof_not_before_ns)
            C.GATE.save(logs/'fixture-proof-records.json',result['actualFixtureProof'])
        result.update(exit=0, tests=len(descriptor['ids']), failures=0, skipped=0, exactIDs=descriptor['ids'], binary=str(binary), binarySHA256=binary_sha,
            symbols=groups, peerTLSDefined=dict(count=len(tls), examples=tls[:5]), final=guard())
    except BaseException as error:
        result.update(exit=125, failure=str(error))
        raise
    finally:
        result['running'] = False
        if (logs/'test-scopes.json').exists():
            result['testScopes'] = json.loads((logs/'test-scopes.json').read_text())['scopes']
        C.GATE.save(logs / 'native.status.json', result)


def ssh_command(parts):
    return SSH + [shlex.join(list(map(str, parts)))]


def _send_lease(process, payload, deadline):
    try:
        process.stdin.write(payload)
        process.stdin.flush()
        return False
    except BrokenPipeError as broken_pipe:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('SSH supervisor deadline exceeded after lease pipe closure') from broken_pipe
        try:
            status = process.wait(timeout=min(3.0, remaining))
        except subprocess.TimeoutExpired as error:
            raise RuntimeError('SSH supervisor remained active after lease pipe closure') from error
        if status != 0:
            if status is None:
                raise RuntimeError('SSH supervisor exit could not be confirmed after lease pipe closure') from broken_pipe
            raise RuntimeError('original remote unit/SSH exit ' + str(status)) from broken_pipe
        if time.monotonic() > deadline:
            raise RuntimeError('SSH supervisor deadline exceeded after lease pipe closure') from broken_pipe
        return True


def stream_stage(root, label, origins, descriptor, manifest_data, manifest_sha, local):
    input_bytes = sum(v['bytes'] for v in descriptor['files']) + len(manifest_data)
    command = ssh_command(['timeout', '120', 'python3', '-I', '-B', '-c', BOOTSTRAP, root, label, manifest_sha, str(input_bytes)])
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=(local / 'stage.log').open('wb'), stderr=subprocess.STDOUT)
    error = None
    try:
        with tarfile.open(fileobj=process.stdin, mode='w|gz') as archive:
            for name, origin in sorted(origins.items()):
                data = origin if isinstance(origin, bytes) else origin.read_bytes()
                row = next(v for v in descriptor['files'] if v['path'] == name)
                if hashlib.sha256(data).hexdigest() != row['sha256']:
                    raise RuntimeError('local input changed during transfer')
                member = tarfile.TarInfo(name); member.size = len(data); member.mode = 0o444
                archive.addfile(member, io.BytesIO(data))
            member = tarfile.TarInfo('stage.json'); member.size = len(manifest_data); member.mode = 0o444
            archive.addfile(member, io.BytesIO(manifest_data))
        process.stdin.close()
        if process.wait(timeout=60) != 0:
            raise RuntimeError('private staging failed; preserve exact root and stage log')
    except BaseException as failure:
        error = failure
    finally:
        error, cleanup = cleanup_preserving(process, error)
        if cleanup:
            C.GATE.save(local / 'stage-cleanup-failure.json', dict(error=cleanup, originalFailure=str(error)))
    if error:
        raise error


def stop_local_process(process):
    if process is None:
        return
    if process.stdin and not process.stdin.closed:
        try:
            process.stdin.close()
        except OSError:
            pass  # The original pipe/run failure is retained by the supervisor.
    if process.poll() is not None:
        process.wait(timeout=1)
        return
    try:
        process.terminate()
        process.wait(timeout=20)
    except BaseException:
        # Terminate/wait errors must not bypass the bounded final kill/wait attempt.
        if process.poll() is None:
            process.kill()
        process.wait(timeout=10)
    if process.poll() is None:
        raise RuntimeError('owned SSH child still running after bounded cleanup')


def cleanup_preserving(process, original):
    try:
        stop_local_process(process)
        return original, None
    except BaseException as error:
        return original or error, str(error)


def close_supervisor(process, local, label, root, session, original):
    original, local_cleanup = cleanup_preserving(process, original)
    remote_cleanup = None
    try:
        output = subprocess.check_output(ssh_command(['python3', '-I', '-B', '-c', CLOSURE, label, root]), timeout=45)
        closure = json.loads(output)
        if closure.get('closed') is not True or closure.get('unit') != label + '.service':
            raise RuntimeError('exact unit closure receipt differs')
        (local / 'remote-closure.json').write_bytes(output)
    except BaseException as error:
        remote_cleanup = str(error)
        original = original or error
    C.GATE.save(local / 'supervisor.status.json', dict(running=False, exit=0 if original is None else 125,
        originalFailure=str(original) if original else None, localCleanupFailure=local_cleanup,
        remoteClosureFailure=remote_cleanup, remoteRoot=str(root), session=session))
    return original


CLOSURE = r'''
import json,os,pathlib,pwd,re,subprocess,sys
label=sys.argv[1];root=pathlib.Path(sys.argv[2]);assert re.fullmatch(r'stash-cluster-b2-20261016-[0-9a-f]{8}',label)
home=pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
assert os.getuid()==1001 and os.getgid()==1001
assert home.is_absolute() and home.resolve()==home and not home.is_symlink() and home.is_dir() and home.stat().st_uid==1001
assert root==home/'.cache'/('tractanda-'+label)
p=subprocess.run(['systemctl','--user','show',label+'.service','-p','LoadState','-p','ActiveState','-p','SubState','-p','MainPID','-p','ControlGroup','-p','ExecStart','-p','Transient'],capture_output=True,text=True,timeout=10)
rows=dict(v.split('=',1) for v in p.stdout.splitlines() if '=' in v)
assert p.returncode in (0,1) and rows.get('LoadState') in ('loaded','not-found')
if rows.get('ActiveState') not in (None,'inactive','failed'):
 assert rows.get('Transient')=='yes' and str(root) in rows.get('ExecStart','')
 subprocess.run(['systemctl','--user','stop',label+'.service'],check=True,timeout=20)
 p=subprocess.run(['systemctl','--user','show',label+'.service','-p','LoadState','-p','ActiveState','-p','SubState','-p','MainPID','-p','ControlGroup'],capture_output=True,text=True,timeout=10)
 rows=dict(v.split('=',1) for v in p.stdout.splitlines() if '=' in v)
 assert p.returncode in (0,1) and rows.get('LoadState') in ('loaded','not-found')
assert rows.get('ActiveState') in (None,'inactive','failed') and rows.get('MainPID','0')=='0'
cg=rows.get('ControlGroup');remaining=[]
if cg:
 q=pathlib.Path('/sys/fs/cgroup')/cg.lstrip('/')
 if q.exists():
  for f in q.rglob('cgroup.procs'):remaining+=f.read_text().split()
  if (q/'cgroup.procs').exists():remaining+=(q/'cgroup.procs').read_text().split()
assert not remaining
print(json.dumps({'unit':label+'.service','state':rows,'remainingProcesses':remaining,'closed':True}))
'''


FETCH = r'''
import io,pathlib,tarfile,sys
root=pathlib.Path(sys.argv[1]);total=0
with tarfile.open(fileobj=sys.stdout.buffer,mode='w|gz') as a:
 for p in sorted((root/'logs').iterdir()):
  assert p.is_file() and not p.is_symlink()
  total+=p.stat().st_size;assert total<=64*1024**2
  a.add(p,arcname=p.name,recursive=False)
'''


def orchestrate(label, checkpoint=None, timeout_seconds=DEFAULT_TIMEOUT_SECONDS,
                command_timeout_seconds=DEFAULT_TIMEOUT_SECONDS):
    command_timeout_seconds = effective_command_timeout(timeout_seconds, command_timeout_seconds)
    budgets = timeout_budgets(timeout_seconds)
    local_capacity = local_space(REPO)
    root = remote_root(resolve_remote_home(), label)
    origins, descriptor = local_inputs(checkpoint)
    manifest_data = (json.dumps(descriptor, indent=2) + '\n').encode()
    manifest_sha = hashlib.sha256(manifest_data).hexdigest()
    session = uuid.uuid4().hex
    local = REPO / 'outputs/verification/cluster-2026-10-16' / label
    local.mkdir(mode=0o700, exist_ok=False)
    (local / 'stage.json').write_bytes(manifest_data)
    process, original_error = None, None
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda number, frame: (_ for _ in ()).throw(InterruptedError('local signal ' + str(number))))
    try:
        stream_stage(root, label, origins, descriptor, manifest_data, manifest_sha, local)
        staged = json.loads((local / 'stage.log').read_text().splitlines()[-1])
        if not staged.get('swiftPath') or not staged.get('PATH') or staged.get('manifestSHA256') != manifest_sha:
            raise RuntimeError('staging/toolchain discovery receipt invalid')
        properties = ['MemoryMax=3221225472', 'MemorySwapMax=0', 'CPUQuota=200%', 'TasksMax=128',
            'RuntimeMaxSec=' + str(budgets['unitRuntimeSeconds']),
            'TimeoutStopSec=15', 'KillMode=control-group', 'OOMPolicy=kill', 'Nice=10']
        command = ['systemd-run', '--user', '--no-ask-password', '--wait', '--pipe', '--unit=' + label]
        command += ['--property=' + v for v in properties]
        command += ['--setenv=PATH=' + staged['PATH']]
        command += ['taskset', '--cpu-list', '0,1', 'python3', '-I', '-B', str(root / 'support/verify-stash-cluster.py'),
                    '--native-root', str(root), '--run-label', label, '--session', session, '--manifest-sha', manifest_sha,
                    '--timeout-seconds', str(timeout_seconds), '--command-timeout-seconds', str(command_timeout_seconds)]
        C.GATE.save(local / 'launch.json', dict(command=command, root=str(root), session=session, sourceSHA256=manifest_sha,
            localCapacity=local_capacity, timeoutBudgets=budgets, commandTimeoutSeconds=command_timeout_seconds,
            remoteResourceLimits=dict(cap=CAP, allowance=ALLOWANCE, reserve=RESERVE, preflight=PREFLIGHT, fixtureCap=FIXTURE_CAP)))
        with (local / 'ssh-run.log').open('wb') as output:
            process = subprocess.Popen(ssh_command(command), stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + budgets['sshOwnerSeconds']
            while process.poll() is None:
                local_space(REPO)
                if time.monotonic() > deadline:
                    raise RuntimeError('SSH supervisor deadline exceeded')
                lease = (json.dumps(dict(session=session, sourceSHA256=manifest_sha)) + '\n').encode()
                if _send_lease(process, lease, deadline):
                    break
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            if process.returncode:
                raise RuntimeError('original remote unit/SSH exit ' + str(process.returncode))
    except BaseException as error:
        original_error = error
    finally:
        previous = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGTERM, signal.SIGHUP)}
        try:
            original_error = close_supervisor(process, local, label, root, session, original_error)
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
    # Retrieve bounded evidence after successful closure even when the remote test failed.
    command = ssh_command(['timeout', '90', 'python3', '-I', '-B', '-c', FETCH, root])
    fetch = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=(local / 'fetch.stderr').open('wb'))
    total = 0
    fetch_error = None
    try:
        with tarfile.open(fileobj=fetch.stdout, mode='r|gz') as archive:
            for member in archive:
                local_space(REPO)
                safe_member(member.name)
                if not member.isfile() or '/' in member.name:
                    raise RuntimeError('invalid result member')
                total += member.size
                if member.size < 0 or total > RESULT_CAP:
                    raise RuntimeError('result evidence cap exceeded')
                with (local / member.name).open('xb') as output:
                    output.write(archive.extractfile(member).read())
        if fetch.wait(timeout=20) != 0:
            raise RuntimeError('bounded evidence retrieval failed')
    except BaseException as error:
        fetch_error = error
        C.GATE.save(local / 'fetch-failure.json', dict(error=str(error), originalFailure=str(original_error)))
    finally:
        fetch_error, cleanup = cleanup_preserving(fetch, fetch_error)
        if cleanup:
            C.GATE.save(local / 'fetch-cleanup-failure.json', dict(error=cleanup, originalFailure=str(original_error or fetch_error)))
    if original_error:
        raise original_error
    if fetch_error:
        raise fetch_error
    status = json.loads((local / 'native.status.json').read_text())
    if status.get('running') is not False or status.get('exit') != 0 or status.get('session') != session or status.get('sourceSHA256') != manifest_sha:
        raise RuntimeError('native completion/source/session mismatch')
    expected_scopes = [('root', descriptor['ids'])] + [(s['name'], s['ids']) for s in descriptor.get('packageTests', [])]
    if [(s['name'], s['ids']) for s in status['testScopes']] != expected_scopes or any(s['state'] != 'passed' for s in status['testScopes']):
        raise RuntimeError('native root/package scope completion differs')
    C.verify_results(json.loads((local / 'tests.status.json').read_text()), (local / 'tests.log').read_text(), descriptor['ids'])
    for scope in descriptor.get('packageTests', []):
        label = 'package-'+scope['name']+'-tests'
        C.verify_results(json.loads((local/(label+'.status.json')).read_text()), (local/(label+'.log')).read_text(), scope['ids'])
    # Never promote a result if the canonical working inputs moved during the run.
    _, final_descriptor = local_inputs(checkpoint)
    if (json.dumps(final_descriptor, indent=2) + '\n').encode() != manifest_data:
        raise RuntimeError('local support or dependency inputs changed during run')
    C.GATE.save(local / 'accepted.json', dict(result=str(len(descriptor['ids'])) + ' passed; zero skips', session=session,
        packageTests={p['name']:len(p['ids']) for p in descriptor.get('packageTests', [])},
        sourceSHA256=manifest_sha, nativeEvidenceSHA256=C.sha(local / 'native.status.json')))
    print(str(local / 'accepted.json'))


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default=HOST, choices=[HOST])
    parser.add_argument('--run-label', required=True)
    parser.add_argument('--native-root', type=Path)
    parser.add_argument('--session')
    parser.add_argument('--manifest-sha')
    parser.add_argument('--source-checkpoint', type=Path)
    parser.add_argument('--timeout-seconds', type=positive_timeout_seconds, default=DEFAULT_TIMEOUT_SECONDS,
                        help='Whole remote test operation budget (default: 24 hours).')
    parser.add_argument('--command-timeout-seconds', type=positive_timeout_seconds, default=DEFAULT_TIMEOUT_SECONDS,
                        help='Maximum per-command test budget, capped by the whole operation.')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    checked_label(args.run_label)
    if args.native_root:
        if args.source_checkpoint:
            raise RuntimeError('source checkpoint is a local admission argument only')
        if not re.fullmatch(r'[0-9a-f]{32}', args.session or '') or not re.fullmatch(r'[0-9a-f]{64}', args.manifest_sha or ''):
            raise RuntimeError('native session/source arguments required')
        native(args.native_root, args.run_label, args.session, args.manifest_sha,
               args.timeout_seconds, args.command_timeout_seconds)
    else:
        if args.session or args.manifest_sha:
            raise RuntimeError('native-only arguments on local supervisor')
        orchestrate(args.run_label, args.source_checkpoint, args.timeout_seconds, args.command_timeout_seconds)


if __name__ == '__main__':
    main()
