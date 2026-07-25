#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' "Eko's verification gate requires macOS: Swift, Xcode, Security.framework, Network.framework, AppKit, CoreBluetooth, and UserNotifications are not available on Linux." >&2
  exit 2
fi

"$SCRIPT_DIR/generate-project.sh"
plutil -lint "$PROJECT_DIR/Config/Info.plist" "$PROJECT_DIR/Config/Eko.entitlements"
swift test --package-path "$PROJECT_DIR"
xcodebuild \
  -project "$PROJECT_DIR/Eko.xcodeproj" \
  -scheme Eko \
  -configuration Debug \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  test
