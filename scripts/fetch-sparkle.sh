#!/bin/sh
# Official binary release, pinned and SHA-256 verified before extraction.
set -eu
cd "$(dirname "$0")/.."
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
ROOT="$PWD/target/sparkle-$VERSION"
ARCHIVE="$PWD/target/Sparkle-$VERSION.tar.xz"
mkdir -p target
if [ ! -f "$ARCHIVE" ]; then
  curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$ARCHIVE.tmp"
  mv "$ARCHIVE.tmp" "$ARCHIVE"
fi
ACTUAL=$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)
[ "$ACTUAL" = "$SHA256" ] || { echo 'Sparkle checksum mismatch; remove the cached archive and retry.' >&2; exit 1; }
if [ ! -f "$ROOT/.verified" ]; then
  STAGE=$(mktemp -d "$PWD/target/sparkle-extract.XXXXXX")
  trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
  tar -xf "$ARCHIVE" -C "$STAGE"
  test -f "$STAGE/Sparkle.framework/Sparkle"
  test -x "$STAGE/bin/generate_appcast"
  touch "$STAGE/.verified"
  rm -rf "$ROOT"
  mv "$STAGE" "$ROOT"
fi
printf '%s\n' "$ROOT"
