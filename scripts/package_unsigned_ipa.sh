#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-build/ios/iphoneos/Runner.app}"
IPA_NAME="${2:-ipa_ci_demo_manual_no_sign.ipa}"

if [ ! -d "$APP_PATH" ]; then
  echo "Missing $APP_PATH. Run: flutter build ios --release --no-codesign" >&2
  exit 1
fi

if [ "$(uname -s)" != Darwin ]; then
  echo "Packaging requires macOS codesign (no certificate is needed)." >&2
  exit 1
fi

OUTPUT_PATH=$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$IPA_NAME")
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/Payload"
STAGED_APP="$STAGING_DIR/Payload/$(basename "$APP_PATH")"
ditto "$APP_PATH" "$STAGED_APP"

# Keep the original bundle identities, URL schemes, and other Info.plist values.
find "$STAGED_APP" -type f -name Info.plist -exec shasum -a 256 {} + \
  | LC_ALL=C sort > "$STAGING_DIR/plists-before.txt"

# Sign loose dylibs first, then nested bundles from the inside out. Use a loop:
# find -exec alone does not reliably propagate a failed codesign to set -e.
while IFS= read -r -d '' dylib; do
  codesign --force --sign - --timestamp=none \
    --preserve-metadata=identifier,entitlements "$dylib"
  codesign --verify --strict "$dylib"
done < <(find "$STAGED_APP" -type f -name '*.dylib' -print0)

while IFS= read -r -d '' bundle; do
  if [ "${bundle##*.}" = bundle ] && \
     ! /usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$bundle/Info.plist" >/dev/null 2>&1; then
    continue
  fi
  codesign --force --sign - --timestamp=none \
    --preserve-metadata=identifier,entitlements "$bundle"
  codesign --verify --strict "$bundle"
done < <(find "$STAGED_APP" -depth -type d \
  \( -name '*.framework' -o -name '*.appex' -o -name '*.app' -o -name '*.bundle' \) -print0)

# Ad-hoc signing creates LC_CODE_SIGNATURE without an Apple certificate. This
# avoids old AltSign/ldid's unsigned-binary buffer-padding assertion. SideStore
# replaces these temporary signatures with the user's Apple ID signatures.
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
find "$STAGED_APP" -type f -name Info.plist -exec shasum -a 256 {} + \
  | LC_ALL=C sort > "$STAGING_DIR/plists-after.txt"
diff -u "$STAGING_DIR/plists-before.txt" "$STAGING_DIR/plists-after.txt"

(cd "$STAGING_DIR" && zip -q -r -y package.ipa Payload)
mv "$STAGING_DIR/package.ipa" "$OUTPUT_PATH"
echo "Created $OUTPUT_PATH (ad-hoc prepared for sideloading; no certificate required)"
