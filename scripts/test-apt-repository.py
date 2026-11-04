#!/usr/bin/env python3
"""Signed repository fixture checks; keys are ephemeral and never used in production."""
import hashlib
import importlib.util
import io
import os
import getpass
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('apt_repo', Path(__file__).with_name('apt-repository.py'))
A = importlib.util.module_from_spec(spec)
spec.loader.exec_module(A)


def deb(path, arch, version='0.1.0~poc.16-1', extra_control=()):
    control = f'Package: tractanda\nVersion: {version}\nArchitecture: {arch}\nMaintainer: Test <test@example.invalid>\nDescription: Private package fixture\n'.encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:xz') as stream:
        entry = tarfile.TarInfo('./control'); entry.size = len(control)
        stream.addfile(entry, io.BytesIO(control))
        for name, payload in extra_control:
            entry = tarfile.TarInfo('./' + name)
            entry.size = len(payload)
            stream.addfile(entry, io.BytesIO(payload))
    with path.open('wb') as stream:
        stream.write(b'!<arch>\n')
        for name, raw in (('debian-binary', b'2.0\n'), ('control.tar.xz', buffer.getvalue())):
            stream.write(f'{name + "/":16}{0:12}{0:6}{0:6}{"100644":8}{len(raw):10}`\n'.encode())
            stream.write(raw)
            if len(raw) % 2: stream.write(b'\n')
    return path


class ControlArchiveTests(unittest.TestCase):
    def test_only_the_layout_inspector_may_exceed_ordinary_control_limit(self):
        payload = hashlib.shake_256(b'bounded fixture control inspector').digest(5 * 1024**2)
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            accepted = deb(directory / 'accepted.deb', 'amd64', '0.1.0~poc.17-1',
                           [('layout17-inspector.tar', payload)])
            self.assertGreater(accepted.stat().st_size, A.CONTROL_METADATA_LIMIT)
            self.assertEqual(A.package(accepted)[1]['Version'], '0.1.0~poc.17-1')
            refused = deb(directory / 'refused.deb', 'amd64', extra_control=[('other', b'0' * (5 * 1024**2))])
            with self.assertRaisesRegex(ValueError, 'ordinary Debian control metadata'):
                A.package(refused)

    def test_layout_inspector_is_limited_to_exact_bridge_family(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for version in ('0.1.0~poc.17-1', '0.1.0~poc.17.1-1'):
                with self.subTest(version=version):
                    path = deb(directory / (version + '.deb'), 'amd64', version,
                               [('layout17-inspector.tar', b'inspector')])
                    self.assertEqual(A.package(path)[1]['Version'], version)
            for version in ('0.1.0~poc.17.2-1', '0.1.0~poc.170-1', '0.1.0~poc.18-1'):
                with self.subTest(version=version), self.assertRaisesRegex(ValueError, 'poc.17 bridge'):
                    A.package(deb(directory / (version + '.deb'), 'amd64', version,
                                  [('layout17-inspector.tar', b'inspector')]))

    def test_expanded_budget_and_inspector_version_are_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            ordinary = deb(directory / 'ordinary.deb', 'amd64')
            with patch.object(A, 'CONTROL_STREAM_LIMIT', 8 * 1024):
                with self.assertRaisesRegex(ValueError, 'Expanded Debian control archive'):
                    A.package(ordinary)
            foreign = deb(directory / 'foreign.deb', 'arm64', extra_control=[('layout17-inspector.tar', b'test')])
            with self.assertRaisesRegex(ValueError, 'poc.17 bridge'):
                A.package(foreign)

    def test_oversized_inspector_and_unsafe_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            oversized = deb(directory / 'oversized.deb', 'amd64', '0.1.0~poc.17-1',
                            [('layout17-inspector.tar', b'12345')])
            with patch.object(A, 'CONTROL_INSPECTOR_LIMIT', 4):
                with self.assertRaisesRegex(ValueError, 'inspector member'):
                    A.package(oversized)
            unsafe = deb(directory / 'unsafe.deb', 'arm64', extra_control=[('../unexpected', b'x')])
            with self.assertRaisesRegex(ValueError, 'Unsafe repository path'):
                A.package(unsafe)

    def test_duplicate_control_or_inspector_remains_invalid(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for name, members in (
                ('duplicate-control', [('control', b'duplicate')]),
                ('duplicate-inspector', [('layout17-inspector.tar', b'first'), ('layout17-inspector.tar', b'second')]),
            ):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    A.package(deb(directory / (name + '.deb'), 'arm64', extra_control=members))


class RepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Darwin Unix socket paths are short; default per-user TMPDIR is too long
        # for GnuPG's agent socket after adding the fixture/home components.
        cls.temp = tempfile.TemporaryDirectory(prefix='trac-apt-', dir='/tmp')
        cls.root = Path(cls.temp.name)
        cls.home = cls.root / 'gnupg'; cls.home.mkdir(mode=0o700)
        cls.gpg = shutil.which('gpg') or '/opt/local/bin/gpg'
        cls.env = patch.dict(os.environ, {'GNUPGHOME': str(cls.home)})
        cls.env.start()
        A.run([cls.gpg, '--batch', '--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key',
               'Tractanda ephemeral fixture <test@example.invalid>', 'ed25519', 'sign', '1d'])
        keys = A.run([cls.gpg, '--with-colons', '--list-keys']).decode()
        cls.fingerprint = next(line.split(':')[9] for line in keys.splitlines() if line.startswith('fpr:'))
        cls.packages = [deb(cls.root / (arch + '.deb'), arch) for arch in A.ARCHES]

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['gpgconf', '--homedir', str(cls.home), '--kill', 'gpg-agent'], capture_output=True)
        cls.env.stop(); cls.temp.cleanup()

    def site(self):
        parent = Path(tempfile.mkdtemp(dir=self.root))
        return parent / 'apt'

    def test_multiarch_signed_indexes_pool_and_by_hash(self):
        site = self.site()
        receipt = A.build(site, self.packages, self.fingerprint, self.gpg)
        self.assertEqual({r['Architecture'] for r in receipt['packages']}, set(A.ARCHES))
        self.assertFalse(receipt['retainedPrevious'])
        self.assertLess(receipt['bytes'], A.SITE_LIMIT)

    def test_tampered_index_package_signature_and_wrong_trust_rejected(self):
        for relative in ('dists/preview/main/binary-amd64/Packages', 'dists/preview/Release',
                         'pool/main/t/tractanda/tractanda_0.1.0~poc.16-1_amd64.deb'):
            with self.subTest(relative=relative):
                site = self.site(); A.build(site, self.packages, self.fingerprint, self.gpg)
                path = site / relative; path.write_bytes(path.read_bytes() + b'tampered')
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    A.verify(site, site / 'tractanda-archive-keyring.asc', self.fingerprint, self.gpg)
        site = self.site(); A.build(site, self.packages, self.fingerprint, self.gpg)
        with self.assertRaisesRegex(ValueError, 'fingerprint'):
            A.verify(site, site / 'tractanda-archive-keyring.asc', '0' * 40, self.gpg)

    def test_bounded_previous_and_current_capacity(self):
        previous = [deb(self.root / ('old-' + a + '.deb'), a, '0.1.0~poc.15-1') for a in A.ARCHES]
        site = self.site(); result = A.build(site, self.packages, self.fingerprint, self.gpg, previous)
        self.assertTrue(result['retainedPrevious']); self.assertEqual(len(result['packages']), 4)
        with self.assertRaisesRegex(ValueError, 'capacity'):
            A.build(self.site(), self.packages, self.fingerprint, self.gpg, limit=1)

    def test_missing_architecture_and_url_paths_fail(self):
        with self.assertRaisesRegex(ValueError, 'both architectures'):
            A.build(self.site(), self.packages[:1], self.fingerprint, self.gpg)
        for value in ('https://example.invalid/package.deb', '../package.deb', '/package.deb', 'pool/../../package.deb'):
            with self.subTest(value=value), self.assertRaises(ValueError): A.safe_relative(value)

    @unittest.skipUnless(shutil.which('apt-get') and shutil.which('apt-cache'), 'Real APT is a Linux qualification')
    def test_real_apt_architecture_candidate_download_and_tamper_rejection(self):
        site = self.site(); A.build(site, self.packages, self.fingerprint, self.gpg)
        for arch in A.ARCHES:
            with self.subTest(arch=arch):
                root = Path(tempfile.mkdtemp(dir=self.root))
                for directory in ('state/lists/partial', 'cache/archives/partial', 'etc', 'downloads'):
                    (root / directory).mkdir(parents=True)
                (root / 'state/status').touch()
                key = root / 'etc/trusted.gpg'
                A.run([self.gpg, '--batch', '--yes', '--output', key, '--dearmor', site / 'tractanda-archive-keyring.asc'])
                (root / 'etc/sources.list').write_text(f'deb [arch={arch} signed-by={key}] file:{site} preview main\n')
                config = root / 'apt.conf'
                config.write_text(f'''Dir::State "{root}/state";
Dir::State::status "{root}/state/status";
Dir::Cache "{root}/cache";
Dir::Etc::sourcelist "{root}/etc/sources.list";
Dir::Etc::sourceparts "-";
Dir::Etc::main "-";
Dir::Etc::parts "-";
Dir::Etc::trusted "{key}";
Dir::Etc::trustedparts "-";
APT::Architecture "{arch}";
APT::Architectures {{ "{arch}"; }};
APT::Sandbox::User "{getpass.getuser()}";
Acquire::Languages "none";
''')
                env = {**os.environ, 'APT_CONFIG': str(config)}
                A.run(['apt-get', 'update', '--error-on=any'], env=env, stderr=subprocess.PIPE)
                policy = A.run(['apt-cache', 'policy', 'tractanda'], env=env).decode()
                self.assertIn('Candidate: 0.1.0~poc.16-1', policy)
                simulation = A.run(['apt-get', '--simulate', 'install', 'tractanda'], env=env, stderr=subprocess.PIPE).decode()
                self.assertIn('Inst tractanda', simulation)
                A.run(['apt-get', 'download', 'tractanda'], env=env, cwd=root / 'downloads', stderr=subprocess.PIPE)
                downloaded = list((root / 'downloads').glob('*.deb'))
                self.assertEqual(len(downloaded), 1)
                self.assertEqual(A.sha(downloaded[0]), A.sha(self.packages[A.ARCHES.index(arch)]))
                # A real APT consumer must reject signed-metadata tampering.
                release = site / 'dists/preview/InRelease'; original = release.read_bytes()
                release.write_bytes(original.replace(b'Label: Tractanda preview', b'Label: Modified preview'))
                attempted = subprocess.run(['apt-get', 'update', '--error-on=any'], env=env, capture_output=True)
                self.assertNotEqual(attempted.returncode, 0)
                release.write_bytes(original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
