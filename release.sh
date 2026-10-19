#!/bin/sh
# Construit Diktation.app, la notarise chez Apple, l'agrafe, puis fabrique
# un DMG lui aussi notarisé et agrafé : dist/Diktation-<version>.dmg.
#
# Prérequis : certificat « Developer ID Application » dans le trousseau et
# un profil notarytool enregistré une fois pour toutes :
#   xcrun notarytool store-credentials "<profil>" --apple-id <email> --team-id <équipe>
# (le mot de passe d'app se tape à l'invite sécurisée de notarytool).
# NOTARY_PROFILE choisit le profil (par défaut : diktation-notary).
set -e
cd "$(dirname "$0")"
PROFILE="${NOTARY_PROFILE:-diktation-notary}"
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
[ -n "$IDENTITY" ] || { echo "Aucun certificat Developer ID Application dans le trousseau."; exit 1; }

./bundle.sh
mkdir -p dist
APP=Diktation.app
ZIP="dist/Diktation-$VERSION.zip"
DMG="dist/Diktation-$VERSION.dmg"

echo "→ Notarisation de l'app…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "→ DMG…"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Diktation $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# Archive zip de l'app agrafée (pour ceux qui préfèrent un zip).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "→ Vérifications…"
spctl -a -vv -t exec "$APP"
spctl -a -vv -t open --context context:primary-signature "$DMG"
(cd dist && shasum -a 256 "Diktation-$VERSION.dmg" "Diktation-$VERSION.zip" > "SHA256SUMS-$VERSION.txt")
echo "OK → $DMG"
