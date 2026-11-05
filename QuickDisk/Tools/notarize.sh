#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 || -z "${NOTARY_PROFILE:-}" ]]; then
  print -u2 "Usage: NOTARY_PROFILE=<keychain-profile> ./Tools/notarize.sh /path/to/QuickDisk.app [output.zip]"
  exit 2
fi

APP="${1:A}"
OUTPUT="${2:-${APP:h}/QuickDisk-notarized.zip}"
[[ -d "$APP" ]] || { print -u2 "App bundle not found: $APP"; exit 2; }

codesign --verify --deep --strict "$APP"
TEMP_ZIP="${TMPDIR:-/tmp}/QuickDisk-notary-$$.zip"
trap 'rm -f "$TEMP_ZIP"' EXIT
ditto -c -k --keepParent "$APP" "$TEMP_ZIP"
xcrun notarytool submit "$TEMP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ditto -c -k --keepParent "$APP" "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
print "Notarized app archive: $OUTPUT"
