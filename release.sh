#!/bin/sh
# Construit Diktation.app, la notarise chez Apple, l'agrafe, puis fabrique
# un DMG lui aussi notarisé et agrafé : dist/Diktation-<version>.dmg.
#
# Prérequis : certificat « Developer ID Application » dans le trousseau et
# un profil notarytool enregistré une fois pour toutes :
#   xcrun notarytool store-credentials "<profil>" --apple-id <email> --team-id <équipe>
# (le mot de passe d'app se tape à l'invite sécurisée de notarytool).
# NOTARY_PROFILE choisit le profil, sinon .notary-profile local, sinon diktation-notary.
set -eu
cd "$(dirname "$0")"
PROFILE="${NOTARY_PROFILE:-diktation-notary}"
if [ -z "${NOTARY_PROFILE:-}" ] && [ -f .notary-profile ]; then
  PROFILE=$(cat .notary-profile)
fi
# Refuse ad-hoc signatures for distributable releases, including inherited overrides.
[ "${DIKTATION_SIGN_IDENTITY:-}" != "-" ] || { echo "A release requires Developer ID signing." >&2; exit 1; }
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
[ -n "$IDENTITY" ] || { echo "Aucun certificat Developer ID Application dans le trousseau."; exit 1; }

# Fail before compiling if notarization credentials have not been configured.
notary() {
  if [ -n "${NOTARY_KEYCHAIN:-}" ]; then
    xcrun notarytool "$@" --keychain-profile "$PROFILE" --keychain "$NOTARY_KEYCHAIN"
  else
    xcrun notarytool "$@" --keychain-profile "$PROFILE"
  fi
}
notary history >/dev/null
export DIKTATION_SIGN_IDENTITY="$IDENTITY"
./bundle.sh
mkdir -p dist
APP=Diktation.app
ZIP="dist/Diktation-$VERSION.zip"
DMG="dist/Diktation-$VERSION.dmg"

echo "→ Notarisation de l'app…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notary submit "$ZIP" --wait --timeout 30m
xcrun stapler staple "$APP"

echo "→ DMG…"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Diktation $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notary submit "$DMG" --wait --timeout 30m
xcrun stapler staple "$DMG"

# Archive zip de l'app agrafée (pour ceux qui préfèrent un zip).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Vérifications…"
spctl -a -vv -t exec "$APP"
spctl -a -vv -t open --context context:primary-signature "$DMG"
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  python3 scripts/make-appcast.py --key-file "$SPARKLE_KEY_FILE"
else
  python3 scripts/make-appcast.py
fi
(cd dist && shasum -a 256 "Diktation-$VERSION.dmg" "Diktation-$VERSION.zip" appcast.xml > "SHA256SUMS-$VERSION.txt")
echo "OK → $DMG"
