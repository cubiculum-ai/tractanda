#!/usr/bin/env python3
"""Wrap a verified macOS release in a signed native Installer product archive.

The normal payload and Bill of Materials describe the final immutable release.
Small pre/post-install scripts protect its destination and register services using
the same native setup tool as install.sh. No second persistent payload tree exists.
"""
import argparse
import hashlib
import json
import html
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def stage_payload(bundle, payload, manifest):
    """Copy manifest data/modes and verify signatures without relying on forks."""
    payload.mkdir(mode=0o755)
    for entry in manifest['files']:
        target = payload / entry['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(bundle / entry['path'], target)
        target.chmod(entry['mode'])
    shutil.copyfile(bundle / 'bundle-manifest.json', payload / 'bundle-manifest.json')
    (payload / 'bundle-manifest.json').chmod(0o644)
    run(payload / 'bin/tractanda-setup', 'plan', '--bundle', payload)
    # All required signatures must live in the copied file data, not resource forks.
    binaries = [payload / 'bin' / name for name in
                ('tractanda', 'tractanda-tui', 'tractanda-mcp', 'tractanda-setup')]
    if manifest.get('embedding'):
        binaries.append(payload / 'bin/tractanda-embeddings')
    if manifest.get('documentExtraction'):
        binaries.append(payload / manifest['documentExtraction']['converterPath'])
    for target in binaries + sorted((payload / 'bin').glob('*.bundle')) + sorted((payload / 'lib').glob('*.dylib')):
        run('/usr/bin/codesign', '--verify', '--strict', target)


def data_archive(source, destination):
    """Use the standard Installer cpio format without macOS metadata sidecars."""
    subprocess.run([
        '/usr/bin/tar', '--format=odc', '--no-xattrs', '--no-acls', '--no-fflags',
        '--no-mac-metadata', '--uid', '0', '--gid', '0', '-czf', str(destination),
        '-C', str(source), '.',
    ], env={**os.environ, 'COPYFILE_DISABLE': '1'}, check=True)


def remove_component_metadata(component, stage, payload, scripts):
    """Keep Apple's package metadata, but omit synthesized AppleDouble entries.

    Current pkgbuild adds metadata BOM entries even when xattr -c cannot remove
    protected provenance attributes. Rebuild the unsigned component's data-only
    archives and full BOM, then let productbuild sign the final product normally.
    """
    expanded = stage / 'component'
    run('/usr/sbin/pkgutil', '--expand', component, expanded)
    listing = subprocess.check_output(['/usr/bin/lsbom', str(expanded / 'Bom')], text=True)
    retained = [line for line in listing.splitlines()
                if not any(part.startswith('._') for part in Path(line.split('\t', 1)[0]).parts)]
    bom_input = stage / 'file-list.txt'
    bom_input.write_text('\n'.join(retained) + '\n')
    run('/usr/bin/mkbom', '-i', bom_input, expanded / 'Bom')
    data_archive(payload, expanded / 'Payload')
    script_archive = stage / 'Scripts.cpio.gz'
    data_archive(scripts, script_archive)
    expanded_scripts = expanded / 'Scripts'
    if expanded_scripts.is_dir():
        shutil.rmtree(expanded_scripts)
    elif expanded_scripts.exists():
        expanded_scripts.unlink()
    script_archive.rename(expanded_scripts)
    for archive in (expanded / 'Payload', expanded / 'Scripts'):
        names = subprocess.check_output(['/usr/bin/tar', '-tzf', str(archive)], text=True).splitlines()
        if any(part.startswith('._') for name in names for part in Path(name).parts):
            raise ValueError('AppleDouble metadata remained in the package archive.')
    inventory = subprocess.check_output(['/usr/bin/lsbom', '-s', '-f', str(expanded / 'Bom')], text=True)
    expected = {p.relative_to(payload).as_posix() for p in payload.rglob('*') if p.is_file()}
    if {p.removeprefix('./') for p in inventory.splitlines()} != expected:
        raise ValueError('Package BOM does not match the release files.')
    info = ET.parse(expanded / 'PackageInfo')
    info.getroot().find('payload').set('numberOfFiles', str(len(retained)))
    info.write(expanded / 'PackageInfo', encoding='utf-8', xml_declaration=True)
    component.unlink()
    # pkgutil --flatten rearchives Scripts even if it is already an archive.
    # Preserve our data-only archives in the standard unsigned XAR component;
    # productbuild signs the complete product after this step.
    subprocess.run(['/usr/bin/xar', '--distribution', '--compression', 'none',
                    '-cf', str(component), 'Bom', 'PackageInfo', 'Payload', 'Scripts'],
                   cwd=expanded, check=True)


def license_html(notice, markdown, model_notices=None, document_notices=None):
    """Render the headings, paragraphs and inline markup used by this license."""
    def inline(text):
        text = html.escape(text)
        text = re.sub(r'&lt;(https?://[^ ]+?)&gt;', r'<a href="\1">\1</a>', text)
        text = re.sub(r'\[([^\]]+)\]\((#[\w-]+|https?://[^ )]+)\)', r'<a href="\2">\1</a>', text)
        text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
        text = re.sub(r'\*\*\*(.+?)\*\*\*', r'<strong><em>\1</em></strong>', text)
        return re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
    parts = ['<!doctype html><html lang="en"><meta charset="utf-8"><title>License</title>',
             '<style>body{font:14px -apple-system,sans-serif;line-height:1.5}h1{font-size:22px}h2{font-size:17px}</style>',
             '<p>' + inline(notice).replace('\n', '<br>') + '</p>']
    for block in markdown.strip().split('\n\n'):
        heading = re.fullmatch(r'(#{1,6}) (.+)', block)
        if heading:
            level, text = len(heading[1]), heading[2]
            anchor = re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')
            parts.append(f'<h{level} id="{anchor}">{inline(text)}</h{level}>')
        elif block.startswith('> '):
            parts.append('<blockquote>' + inline(block[2:]) + '</blockquote>')
        else:
            parts.append('<p>' + inline(block).replace('\n', ' ') + '</p>')
    if model_notices:
        parts.append('<h1>Bundled model and tokenizer</h1>')
        parts.append('<p>' + inline((model_notices / 'NOTICE').read_text()).replace('\n', '<br>') + '</p>')
        for name, title in (('Gemma-Terms.html', 'Gemma Terms of Use'),
                            ('Gemma-Prohibited-Use-Policy.html', 'Gemma Prohibited Use Policy')):
            document = (model_notices / name).read_text()
            text = re.search(r'<pre>(.*?)</pre>', document, re.S)
            if not text:
                raise ValueError('Missing plain legal text in ' + name)
            parts.append('<h2>' + title + '</h2><pre style="white-space:pre-wrap;font:inherit">'
                         + text[1] + '</pre>')
    if document_notices:
        parts.append('<h1>Bundled native document model</h1>')
        parts.append('<p>' + inline((document_notices / 'Granite-Docling-MODEL-NOTICE.md').read_text()).replace('\n', '<br>') + '</p>')
        for name, title in (('Granite-Docling-LICENSE', 'Granite Docling Apache 2.0 license'),
                            ('Pillow-LICENSE', 'Pillow preprocessing license')):
            parts.append('<h2>' + title + '</h2><pre style="white-space:pre-wrap;font:inherit">'
                         + html.escape((document_notices / name).read_text()) + '</pre>')
    return '\n'.join(parts) + '\n</html>\n'


def make_distribution(manifest, identifier, component_name, sample_identifier, sample_component_name):
    distribution = ET.Element('installer-gui-script', minSpecVersion='2')
    ET.SubElement(distribution, 'title').text = 'Tractanda ' + manifest['version']
    ET.SubElement(distribution, 'options', customize='allow', require_scripts='true', hostArchitectures='arm64')
    ET.SubElement(distribution, 'domains', enable_anywhere='false', enable_currentUserHome='false', enable_localSystem='true')
    volume = ET.SubElement(distribution, 'volume-check')
    ET.SubElement(ET.SubElement(volume, 'allowed-os-versions'), 'os-version', min='15.0')
    ET.SubElement(distribution, 'welcome', file='Welcome.html', **{'mime-type': 'text/html'})
    ET.SubElement(distribution, 'license', file='License.html', **{'mime-type': 'text/html'})
    ET.SubElement(distribution, 'conclusion', file='Conclusion.html', **{'mime-type': 'text/html'})
    outline = ET.SubElement(distribution, 'choices-outline')
    ET.SubElement(outline, 'line', choice='tractanda')
    ET.SubElement(outline, 'line', choice='sample-store')
    description = ('Shared server, terminal client, local embeddings and native document extraction'
                   if manifest.get('documentExtraction') else 'Shared server, terminal client and local embeddings')
    choice = ET.SubElement(distribution, 'choice', id='tractanda', title='Tractanda', description=description,
                           selected='true', enabled='false')
    ET.SubElement(choice, 'pkg-ref', id=identifier)
    sample = ET.SubElement(distribution, 'choice', id='sample-store', title='Initialize a sample store',
                           description='Deselect to install software only, for example before joining an existing cluster.',
                           start_selected='true')
    ET.SubElement(sample, 'pkg-ref', id=sample_identifier)
    ET.SubElement(distribution, 'pkg-ref', id=identifier, version=manifest['version'], auth='Root',
                  **{'installKBytes': str((sum(f['size'] for f in manifest['files']) + 1023) // 1024)}).text = component_name
    ET.SubElement(distribution, 'pkg-ref', id=sample_identifier, version=manifest['version'], auth='Root').text = sample_component_name
    return distribution


def render_conclusion(template, release):
    join_command = ('"' + release + '/bin/tractanda" cluster join --prepare-new production '
                    + '--hostname HOSTNAME')
    if template.count('@FRESH_TARGET_JOIN@') != 1:
        raise ValueError('Conclusion must contain exactly one fresh target join placeholder.')
    return template.replace('@FRESH_TARGET_JOIN@', html.escape(join_command))


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
    digest = hashlib.sha256((bundle / 'bundle-manifest.json').read_bytes()).hexdigest()
    release = '/Library/Tractanda/Software/releases/' + manifest['version'] + '-' + digest[:12]
    with tempfile.TemporaryDirectory(prefix='tractanda-pkg-') as directory:
        stage = Path(directory)
        scripts, resources, sample_scripts = stage / 'scripts', stage / 'resources', stage / 'sample-scripts'
        scripts.mkdir(); resources.mkdir(); sample_scripts.mkdir()
        payload = stage / 'payload'
        stage_payload(bundle, payload, manifest)
        for name in ('preinstall', 'postinstall'):
            shutil.copy2(root / 'scripts/macos-package' / name, scripts / name)
            (scripts / name).chmod(0o755)
        (scripts / 'release-path').write_text(release + '\n')
        shutil.copy2(root / 'scripts/macos-package/postinstall-sample', sample_scripts / 'postinstall')
        (sample_scripts / 'postinstall').chmod(0o755)
        (sample_scripts / 'release-path').write_text(release + '\n')
        setup_hash = next(f['sha256'] for f in manifest['files'] if f['path'] == 'bin/tractanda-setup')
        (scripts / 'setup-sha256').write_text(setup_hash + '\n')
        shutil.copy2(root / 'scripts/macos-package/Welcome.html', resources / 'Welcome.html')
        conclusion = (root / 'scripts/macos-package/Conclusion.html').read_text()
        (resources / 'Conclusion.html').write_text(render_conclusion(conclusion, release))
        (resources / 'License.html').write_text(license_html(
            (root / 'NOTICE').read_text(), (root / 'LICENSE').read_text(),
            bundle / 'licenses/Granite' if manifest.get('embedding') else None,
            bundle / 'licenses/Docling' if manifest.get('documentExtraction') else None))
        component = stage / 'Tractanda.pkg'
        components = stage / 'components.plist'
        run('/usr/bin/pkgbuild', '--analyze', '--root', payload, components)
        entries = plistlib.loads(components.read_bytes())
        for entry in entries:
            entry.update(BundleIsRelocatable=False, BundleIsVersionChecked=False, BundleOverwriteAction='upgrade')
        components.write_bytes(plistlib.dumps(entries))
        run('/usr/bin/pkgbuild', '--root', payload, '--install-location', release,
            '--component-plist', components, '--ownership', 'recommended', '--scripts', scripts,
            '--identifier', identifier, '--version', manifest['version'], component)
        remove_component_metadata(component, stage, payload, scripts)
        sample_identifier = identifier + '.sample-store'
        sample_component = stage / 'TractandaSampleStore.pkg'
        run('/usr/bin/pkgbuild', '--nopayload', '--scripts', sample_scripts,
            '--identifier', sample_identifier, '--version', manifest['version'], sample_component)
        distribution = make_distribution(manifest, identifier, component.name,
                                         sample_identifier, sample_component.name)
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
