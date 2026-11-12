#!/usr/bin/env python3
"""Import only explicitly configured GitHub secrets into an ephemeral release runner."""
import base64
import os
import secrets
import subprocess
from pathlib import Path

REQUIRED = ('DEVELOPER_ID_P12', 'DEVELOPER_ID_PASSWORD', 'APPLE_ID',
            'APPLE_APP_PASSWORD', 'APPLE_TEAM_ID', 'SPARKLE_PRIVATE_KEY')
missing = [name for name in REQUIRED if not os.environ.get(name)]
if missing:
    raise SystemExit('Missing release secrets: ' + ', '.join(missing))
root = Path(os.environ['RUNNER_TEMP'])
keychain = root / 'diktation-release.keychain-db'
certificate = root / 'diktation-certificate.p12'
sparkle_key = root / 'diktation-sparkle.key'
os.umask(0o077)
certificate.write_bytes(base64.b64decode(os.environ['DEVELOPER_ID_P12'], validate=True))
sparkle_key.write_text(os.environ['SPARKLE_PRIVATE_KEY'].strip() + '\n')
password = secrets.token_urlsafe(32)


def run(*args):
    # Do not echo commands or subprocess output that might include credential values.
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise SystemExit(f'Signing setup failed during {args[0]} {args[1]}; check the configured secrets.')

run('security', 'create-keychain', '-p', password, str(keychain))
run('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
run('security', 'unlock-keychain', '-p', password, str(keychain))
run('security', 'import', str(certificate), '-P', os.environ['DEVELOPER_ID_PASSWORD'],
    '-k', str(keychain), '-T', '/usr/bin/codesign', '-T', '/usr/bin/security')
run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, str(keychain))
run('security', 'list-keychains', '-d', 'user', '-s', str(keychain))
# Explicit keychain ensures notarytool writes to the disposable runner keychain.
run('xcrun', 'notarytool', 'store-credentials', 'diktation-ci', '--keychain', str(keychain),
    '--apple-id', os.environ['APPLE_ID'], '--team-id', os.environ['APPLE_TEAM_ID'],
    '--password', os.environ['APPLE_APP_PASSWORD'])
certificate.unlink()
print('Release signing credentials imported into temporary keychain.')
