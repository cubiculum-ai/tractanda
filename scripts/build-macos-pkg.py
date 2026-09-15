#!/usr/bin/env python3
"""Wrap a verified macOS release in a signed native Installer product archive.

The package's private script resources carry the bundle. The native setup tool
performs the same verified installation/upgrade used by install.sh; the OS cleans
up temporary Installer resources. No second persistent payload tree is installed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sign-identity', required=True, help='Developer ID Installer certificate name or SHA-1')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    bundle, output = args.bundle.resolve(), args.output.resolve()
    if output.exists():
        parser.error('Output must not exist.')
    manifest = json.loads((bundle / 'bundle-manifest.json').read_text())
    if manifest['platform'] != 'macos' or manifest['arch'] != 'arm64':
        parser.error('This preview package targets macOS arm64.')
    # Also validates all manifest paths, modes and hashes before packaging resources.
    run(bundle / 'bin/tractanda-setup', 'plan', '--bundle', bundle)
    identifier = 'ai.tractanda.preview'
    with tempfile.TemporaryDirectory(prefix='tractanda-pkg-') as directory:
        stage = Path(directory)
        scripts, resources = stage / 'scripts', stage / 'resources'
        scripts.mkdir(); resources.mkdir()
        shutil.copytree(bundle, scripts / 'bundle')
        shutil.copy2(root / 'scripts/macos-package/postinstall', scripts / 'postinstall')
        (scripts / 'postinstall').chmod(0o755)
        for name in ('Welcome.html', 'Conclusion.html'):
            shutil.copy2(root / 'scripts/macos-package' / name, resources / name)
        (resources / 'License.txt').write_text((root / 'NOTICE').read_text() + '\n' + (root / 'LICENSE').read_text())
        component = stage / 'Tractanda.pkg'
        run('/usr/bin/pkgbuild', '--nopayload', '--scripts', scripts,
            '--identifier', identifier, '--version', manifest['version'], component)
        distribution = ET.Element('installer-gui-script', minSpecVersion='2')
        ET.SubElement(distribution, 'title').text = 'Tractanda ' + manifest['version']
        ET.SubElement(distribution, 'options', customize='never', require_scripts='true', hostArchitectures='arm64')
        ET.SubElement(distribution, 'domains', enable_anywhere='false', enable_currentUserHome='false', enable_localSystem='true')
        volume = ET.SubElement(distribution, 'volume-check')
        ET.SubElement(ET.SubElement(volume, 'allowed-os-versions'), 'os-version', min='15.0')
        ET.SubElement(distribution, 'welcome', file='Welcome.html', **{'mime-type': 'text/html'})
        ET.SubElement(distribution, 'license', file='License.txt', **{'mime-type': 'text/plain'})
        ET.SubElement(distribution, 'conclusion', file='Conclusion.html', **{'mime-type': 'text/html'})
        ET.SubElement(ET.SubElement(distribution, 'choices-outline'), 'line', choice='tractanda')
        choice = ET.SubElement(distribution, 'choice', id='tractanda', title='Tractanda', description='Shared server, terminal client and local embeddings')
        ET.SubElement(choice, 'pkg-ref', id=identifier)
        ET.SubElement(distribution, 'pkg-ref', id=identifier, version=manifest['version'], auth='Root',
                      **{'installKBytes': str((sum(f['size'] for f in manifest['files']) + 1023) // 1024)}).text = component.name
        xml = stage / 'Distribution.xml'
        ET.indent(distribution)
        ET.ElementTree(distribution).write(xml, encoding='utf-8', xml_declaration=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        run('/usr/bin/productbuild', '--distribution', xml, '--package-path', stage,
            '--resources', resources, '--sign', args.sign_identity, '--timestamp', output)
        run('/usr/sbin/pkgutil', '--check-signature', output)
        digest = hashlib.sha256()
        with output.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        checksum = digest.hexdigest()
        print(json.dumps({'package': str(output), 'sha256': checksum, 'signed': True,
                          'notarized': False, 'bundleVersion': manifest['version']}, indent=2))


if __name__ == '__main__':
    main()
