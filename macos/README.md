# Eko for macOS

Eko is a sandboxed macOS 14 menu-bar app. `EkoCore` is a Swift package containing persistence,
protocol, security, networking, discovery, and OS-service boundaries. The `Eko` application target
is generated reproducibly with XcodeGen.

## Generate and build

Requirements: macOS 14 or newer, Xcode 16.3 or newer, Node.js, and XcodeGen.

```sh
brew install xcodegen
./Scripts/generate-project.sh
xcodebuild -project Eko.xcodeproj -scheme Eko -configuration Debug build test
```

The icon generator has no third-party dependencies and deterministically writes every required
macOS icon size before project generation. SwiftPM resolves exact GRDB, Yams, swift-certificates,
and swift-crypto versions from `Package.swift`.

Notification delivery, Local Network privacy attribution, Keychain identities, launch at login,
Bluetooth advertising, hardened runtime, and sandbox behavior require a signed build. Release
archives should use a Developer ID Application certificate, notarization with `notarytool`, and
stapling before distribution.

## Package tests

```sh
swift test
```

The package intentionally targets macOS because Network.framework, Security.framework, AppKit,
CoreBluetooth, ServiceManagement, and UserNotifications are production dependencies rather than
Linux mocks.

Run the complete project, package, plist, and app-hosted test gate with:

```sh
./Scripts/verify-macos.sh
```
