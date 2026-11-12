#!/bin/sh
# Explicit publication step. A matching pushed tag and notarized artifacts are required.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
TAG="v$VERSION"
REPO=$(python3 -c 'import json; print(json.load(open("app/updates.json"))["repository"])')
[ -z "$(git status --porcelain --untracked-files=normal)" ] || { echo 'Commit the release sources before publishing.' >&2; exit 1; }
[ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || { echo 'The release tag must point to the checked-out commit.' >&2; exit 1; }
# Never overwrite an already-published version.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists; use a new version." >&2; exit 1
fi
# Do not replace the live update feed with an older version on a delayed tag run.
LATEST=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
python3 - "$VERSION" "$LATEST" <<'PY'
import re, sys
def version(value):
    if not re.fullmatch(r'v?\d+\.\d+\.\d+', value):
        raise SystemExit('Only stable major.minor.patch releases can update the live feed.')
    return tuple(map(int, value.removeprefix('v').split('.')))
if version(sys.argv[1]) <= version(sys.argv[2]):
    raise SystemExit('The release must be newer than the currently published version.')
PY
(cd dist && shasum -a 256 -c "SHA256SUMS-$VERSION.txt")
xcrun stapler validate Diktation.app
spctl -a -vv -t exec Diktation.app
python3 - <<'PY'
import importlib.util,json,re
from pathlib import Path
spec=importlib.util.spec_from_file_location('appcast','scripts/make-appcast.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
v=re.search(r'^version = "([^"]+)"',Path('Cargo.toml').read_text(),re.M)[1]
m.verify(Path('dist/appcast.xml'),Path(f'dist/Diktation-{v}.zip'),v,json.loads(Path('app/updates.json').read_text()))
PY
# Draft first: all assets must be uploaded successfully before clients can discover the feed.
gh release create "$TAG" --repo "$REPO" --verify-tag --draft --title "Diktation $VERSION" \
  --notes-file "docs/releases/$VERSION.md" \
  "dist/Diktation-$VERSION.dmg" "dist/Diktation-$VERSION.zip" dist/appcast.xml "dist/SHA256SUMS-$VERSION.txt"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
