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
# Xcode 16's build system can race SwiftPM package-product frameworks when
# building tests: a product framework links against a sibling product whose
# PackageFrameworks/ binary has not been produced yet ("clang: error: no such
# file or directory: .../PackageFrameworks/Crypto_..."). The dependency graph
# is complete on a retry because the first pass leaves the missing framework
# behind, so build for testing with one retry, then test without rebuilding.
build_for_testing() {
  xcodebuild \
    -project "$PROJECT_DIR/Eko.xcodeproj" \
    -scheme Eko \
    -configuration Debug \
    -destination "platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing
}
build_for_testing || build_for_testing
xcodebuild \
  -project "$PROJECT_DIR/Eko.xcodeproj" \
  -scheme Eko \
  -configuration Debug \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building
