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
# The full test suite already ran above via `swift test` — the package's
# EkoTests target and the Xcode project's EkoTests target share the same
# Tests/EkoTests sources. The xcodebuild step therefore only needs to prove
# the generated project builds the app.
#
# It deliberately runs `build`, not `test`: Xcode 16's test actions package
# SwiftPM products as dynamic PackageFrameworks, and swift-crypto's Crypto
# module is a CryptoKit re-export shim with no object code on macOS — Xcode
# creates its framework bundle but emits no binary, and X509's framework
# deterministically fails to link against it ("clang: error: no such file
# ... PackageFrameworks/Crypto_..."). Plain builds link packages statically
# and do not hit this. Revisit app-hosted tests when Xcode handles empty
# package products in PackageFrameworks.
xcodebuild \
  -project "$PROJECT_DIR/Eko.xcodeproj" \
  -scheme Eko \
  -configuration Debug \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  build
