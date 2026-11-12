#!/usr/bin/env python3
"""Generate the signed feed from exactly one release archive; verify before publication."""
import argparse
import json
import plistlib
import zipfile
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def verify(feed, archive, version, config):
    with zipfile.ZipFile(archive) as package:
        info = plistlib.loads(package.read('Diktation.app/Contents/Info.plist'))
    expected_info = {'CFBundleIdentifier': 'dev.local.diktation', 'CFBundleVersion': version,
                     'SUPublicEDKey': config['public_ed_key'], 'SUFeedURL': config['feed_url'],
                     'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}
    if any(info.get(key) != value for key, value in expected_info.items()):
        raise ValueError('Archive identity, version or update security configuration mismatch')
    channel = ET.parse(feed).getroot().find('channel')
    items = channel.findall('item') if channel is not None else []
    if len(items) != 1:
        raise ValueError('Expected exactly one release in this appcast')
    item = items[0]
    if item.findtext(NS + 'version') != version:
        raise ValueError('Appcast version does not match Cargo.toml')
    if item.findtext(NS + 'minimumSystemVersion') != '14.0':
        raise ValueError('Unexpected minimum macOS version')
    enclosure = item.find('enclosure')
    expected = f'https://github.com/{config["repository"]}/releases/download/v{version}/{archive.name}'
    if enclosure is None or enclosure.get('url') != expected:
        raise ValueError('Appcast points to an unexpected archive')
    if int(enclosure.get('length', '-1')) != archive.stat().st_size:
        raise ValueError('Archive length mismatch')
    signature = enclosure.get(NS + 'edSignature')
    if not signature:
        raise ValueError('Missing Ed25519 signature')
    subprocess.run(['swift', str(ROOT / 'scripts/verify-update.swift'), str(archive),
                    config['public_ed_key'], signature], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--key-file', type=Path, help='Optional private key file (CI); local builds use Keychain')
    args = parser.parse_args()
    config = json.loads((ROOT / 'app/updates.json').read_text())
    version = re.search(r'^version = "([^"]+)"', (ROOT / 'Cargo.toml').read_text(), re.M)[1]
    archive = ROOT / 'dist' / f'Diktation-{version}.zip'
    notes = ROOT / 'docs/releases' / f'{version}.md'
    if not archive.is_file() or not notes.is_file():
        raise SystemExit('Build the release archive and write its release notes first')
    sparkle = Path(subprocess.check_output([str(ROOT / 'scripts/fetch-sparkle.sh')], text=True).strip())
    signing = ['--ed-key-file', str(args.key_file.resolve())] if args.key_file else ['--account', config['keychain_account']]
    feed = ROOT / 'dist/appcast.xml'
    # No stale DMG/ZIP or old appcast from another build can enter this feed.
    with tempfile.TemporaryDirectory(prefix='diktation-appcast-') as directory:
        stage = Path(directory)
        shutil.copy2(archive, stage / archive.name)
        shutil.copy2(notes, stage / f'{archive.stem}.md')
        subprocess.run([str(sparkle / 'bin/generate_appcast'), *signing,
                        '--download-url-prefix', f'https://github.com/{config["repository"]}/releases/download/v{version}/',
                        '--embed-release-notes', '--maximum-deltas', '0', str(stage)], check=True)
        generated = stage / 'appcast.xml'
        verify(generated, archive, version, config)
        subprocess.run([str(sparkle / 'bin/sign_update'), *signing, '--verify', str(generated)], check=True)
        shutil.copy2(generated, feed)
    print(f'Signed and verified feed: {feed}')

if __name__ == '__main__':
    main()
