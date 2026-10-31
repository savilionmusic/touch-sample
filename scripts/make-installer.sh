#!/bin/bash
# Builds Touch Sample.app into dist/.stage (so a running dist/Touch Sample.app is not overwritten mid-run),
# wraps it in an installer package on the Desktop, then swaps the staged app into dist/ by rename.
# The package holds only the app bundle (hard rule 1): no firmware, sdcard, vendor or other emulator files.
# The installed app finds the emulator folder in this repo through the TouchSampleRoot key in its Info.plist.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/dist/.stage"
PAYLOAD="$STAGE/root"
APP="$PAYLOAD/Touch Sample.app"
rm -rf "$STAGE"; mkdir -p "$PAYLOAD"

TOUCH_SAMPLE_APP_OUT="$APP" "$ROOT/scripts/build-app.sh"   # includes the ad-hoc codesign
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="${TOUCH_SAMPLE_PKG_OUT:-$HOME/Desktop/Touch Sample $VERSION ($(date +%Y-%m-%d)) Installer.pkg}"

# Not relocatable: otherwise Installer may update another copy of the same bundle id (dist/Touch Sample.app)
# instead of putting the app in /Applications.
PLIST="$STAGE/component.plist"
pkgbuild --analyze --root "$PAYLOAD" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" -c "Set :0:BundleIsVersionChecked false" "$PLIST"
pkgbuild --root "$PAYLOAD" --component-plist "$PLIST" --install-location /Applications \
  --identifier com.savilion.touchsample.pkg --version "$VERSION" --ownership recommended "$OUT"

# Payload must be the app bundle and nothing else (entries starting ._ are extended attributes of bundle files).
EXTRA="$(pkgutil --payload-files "$OUT" | grep -Ev '^\.(/(\._)?Touch Sample\.app(/.*)?)?$' || true)"
if [ -n "$EXTRA" ]; then echo "Unexpected files in the installer payload:" >&2; echo "$EXTRA" >&2; exit 1; fi
pkgutil --expand "$OUT" "$STAGE/expanded"
grep -q 'relocatable="false"' "$STAGE/expanded/PackageInfo" || { echo "Package is relocatable" >&2; exit 1; }

# Make dist/ match the installer. Rename, never overwrite, so a running copy keeps its files.
DIST_APP="$ROOT/dist/Touch Sample.app"
if [ -e "$DIST_APP" ]; then
  PREVIOUS="${TOUCH_SAMPLE_PREVIOUS:-$ROOT/dist/Touch Sample.app.previous}"
  if [ -e "$PREVIOUS" ]; then PREVIOUS="$PREVIOUS.$(date +%s)"; fi
  mv "$DIST_APP" "$PREVIOUS"
  echo "Previous dist app moved to $PREVIOUS"
fi
mv "$APP" "$DIST_APP"
rm -rf "$STAGE"
echo "Built $DIST_APP"
echo "Installer: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
