# Release signing and notarization checklists

## Inputs and release record

Create one restricted release record before building. Record:

- Marketing version, build number, Git commit, protocol range, Android schema version, and Mac schema
  version.
- Android application ID and expected release-certificate SHA-256 digest.
- Apple Team ID, bundle ID, Developer ID certificate identity, and notarization submission ID.
- Build host/toolchain versions, target/compile SDK, Xcode version, and dependency lockfile digests.
- Required hardware-spike and manual-QA reports.
- SHA-256 digest and size of every published artifact.

Build from the recorded commit with a clean release configuration. Signing secrets must come from the
approved secret store, never repository files, shell history, CI logs, diagnostics, or release
archives.

## Common preflight

- [ ] All automated tests, protocol vectors, database migration fixtures, OTP corpus, and deterministic
  chaos runs pass.
- [ ] Manual QA passes on the required Android/macOS matrix.
- [ ] Hardware gates S1-S11 have current evidence where required; S9 battery and S10 physical
  power-loss are mandatory M3 release gates.
- [ ] User-facing English and German strings are complete; these English operational documents match
  actual menus and behavior.
- [ ] No private keys, signing files, provisioning credentials, diagnostic archives, synthetic test
  secrets, or production endpoints are present in artifacts or source changes.
- [ ] Version negotiation and forward-only Android/Mac migrations are tested from every supported
  public release.
- [ ] Backup exclusions, retention defaults, diagnostics default redaction, and no-telemetry behavior
  are verified in the built artifacts.
- [ ] Release notes identify security/privacy changes, schema changes, permission changes, known OEM
  limitations, and whether re-pairing is required. Normal updates must not require re-pairing.

## Android signing

The Android release keystore is a product identity and recovery asset. A casual key rotation forces
uninstall/reinstall and destroys outbox data, grants, associations, and pairings.

### Key custody

- [ ] Use the established release key, not a debug key or a newly generated replacement.
- [ ] Keep at least two encrypted, access-controlled backups in separate failure domains and test
  recovery without exposing the key material.
- [ ] Restrict signing to named release operators/CI identities and record every use.
- [ ] Keep keystore password, key password, alias, and binary separate where practical.
- [ ] Compare the public certificate digest with the prior release and the release record before
  upload.

### Build inspection

- [ ] Build the universal release APK with `compileSdk 36` and `targetSdk 36` for v1.
- [ ] Confirm min SDK and bundled Conscrypt behavior match the supported API 26-28 policy.
- [ ] Confirm release debuggability is false and no test-only activities, providers, trust managers,
  cleartext overrides, or verbose payload logging remain.
- [ ] Inspect permissions. Eko v1 must not request `READ_SMS`, `RECEIVE_SMS`, Accessibility,
  `QUERY_ALL_PACKAGES`, overlay, exact alarm, or Android 17 `ACCESS_LOCAL_NETWORK` while targeting 36.
- [ ] Confirm notification listener and companion service declarations have the intended exported and
  system-binding permissions.
- [ ] Confirm `dataExtractionRules` and legacy `fullBackupContent` exclude outbox, active state,
  identity, certificates, pins, and connection epoch.
- [ ] Confirm the foreground service declares `connectedDevice`, not `dataSync`, and includes its
  required normal permissions.

Use Android build-tools from the recorded SDK. With `APK` set to the release artifact:

```sh
apksigner verify --verbose --print-certs "$APK"
apkanalyzer manifest application-id "$APK"
apkanalyzer manifest min-sdk "$APK"
apkanalyzer manifest target-sdk "$APK"
sha256sum "$APK"
```

On macOS, `shasum -a 256 "$APK"` is an equivalent checksum command. Record the signer certificate
SHA-256 digest exactly; do not compare only the subject name.

### Upgrade and distribution

- [ ] Install the previous public APK, pair it, commit unsent events, and update in place with the
  candidate. Verify package manager accepts the signature and identity/high-water/grants/CDM state
  survive.
- [ ] Test fresh browser/file-manager and Obtainium installs on Android 13+ including restricted
  settings.
- [ ] Verify the GitHub release and Obtainium source resolve to the same signed bytes.
- [ ] Publish APK, checksum file, release notes, and signing-certificate digest over the release host.
- [ ] Register/verify the package name and release certificate in Android Developer Console before
  developer-verification enforcement applies to the distribution audience.
- [ ] Never replace an uploaded artifact under the same version. Rebuilds get a new build number and
  a new release record.

## macOS Developer ID and notarization

### Build and entitlement inspection

- [ ] Archive a Release build with the established Developer ID Application identity and hardened
  runtime.
- [ ] Confirm `LSUIElement`, minimum macOS 14, bundle/version values, and designated requirement.
- [ ] Confirm `com.apple.security.app-sandbox`, `com.apple.security.network.server`,
  `com.apple.security.network.client`, and `com.apple.security.device.bluetooth` match the design.
  Reject undocumented temporary exceptions.
- [ ] Confirm `NSLocalNetworkUsageDescription`, `_eko._tcp` Bonjour declaration, and
  `NSBluetoothAlwaysUsageDescription` are present and user-facing.
- [ ] Confirm all nested frameworks/helpers are signed by the expected Team ID before the outer app is
  signed. Do not use ad-hoc signatures or `--deep` as a substitute for correct inside-out signing.
- [ ] Confirm the data-protection Keychain identity persists across update and the app does not bundle
  a private identity key.
- [ ] Launch from `/Applications` and verify local notifications, TCC attribution, and launch at login
  using the signed candidate.

Inspect the final app before packaging. With `APP` set to the candidate path:

```sh
codesign --verify --strict --verbose=2 "$APP"
codesign --display --verbose=4 "$APP"
codesign --display --entitlements :- "$APP"
spctl --assess --type execute --verbose=4 "$APP"
```

Review command output rather than treating exit zero from only one tool as sufficient. `codesign
--deep` may be added as a diagnostic check, but release correctness depends on individually valid
nested signatures.

### Submit and staple

Package the signed app in the intended ZIP, DMG, or installer before notarization. Store App Store
Connect credentials in a Keychain profile created out of band. With `ARTIFACT` and `NOTARY_PROFILE`
set to those recorded values:

```sh
xcrun notarytool submit "$ARTIFACT" --keychain-profile "$NOTARY_PROFILE" --wait
```

- [ ] Require an `Accepted` result and save the submission ID in the release record.
- [ ] If rejected or invalid, fetch the notarization log, fix the build, increment the build number,
  and submit a new artifact. Do not staple or publish a failed submission.
- [ ] Staple the ticket to the app/DMG/package type Apple supports, then validate it.

For an app bundle:

```sh
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
```

If the downloadable artifact is a DMG or installer package, staple and validate that outer artifact
as well. Recompute its SHA-256 after stapling; stapling changes bytes.

### Gatekeeper and update validation

- [ ] Download the published bytes on a clean supported Mac instead of copying the local build output.
- [ ] Disconnect the test Mac from the network after download and verify the stapled ticket permits
  first launch without a bypass.
- [ ] Verify quarantine is present on the downloaded artifact and Gatekeeper identifies the expected
  developer/Team ID.
- [ ] Test fresh consent for notifications, Local Network, and Bluetooth from a fresh user or VM
  snapshot.
- [ ] Update over the previous public build and verify Keychain identity, peer pins, database,
  launch-at-login state, and TCC attribution remain stable.
- [ ] Verify only one copy is used in `/Applications`; duplicate copies must not be recommended because
  they confuse Local Network settings and login registration.

## Artifact publication

- [ ] Publish immutable Android and macOS artifacts, detached checksum text, release notes, and source
  reference together.
- [ ] Download every artifact from the public location and recalculate SHA-256 and size against the
  release record.
- [ ] Verify update metadata points to the final immutable, notarized/signed bytes and uses the right
  version/build ordering.
- [ ] Keep signing keys, notarization credentials, debug symbols containing private local paths, and
  unredacted diagnostics out of the public release.
- [ ] Preserve symbols privately for crash diagnosis under the project's retention/access policy.
- [ ] Announce any permission or data-handling change prominently, not only in a changelog diff.

## Go/no-go

Do not release when any of these is true:

- The Android signing digest or Apple Team ID differs unexpectedly.
- Notarization is not accepted and stapled, or Gatekeeper needs a user bypass.
- Upgrade loses identity, grants, associations, cursor, committed rows, or history without an
  explicitly designed migration.
- Event-or-gap coverage, invalid-ACK rejection, generation reset, diagnostics redaction, or backup
  exclusion fails.
- S9 exceeds the battery budget without an accepted product change, or S10 lacks physical power-loss
  evidence for the published durability claim.
- A required TCC, accessibility, Android 15/16 redaction, restricted-settings, or OEM matrix case is
  untested or has a release-blocking defect.

If a published artifact is bad, remove it from update metadata, preserve it for incident analysis
under restricted access, publish a new version/build, and keep the same valid identity keys. Never
silently replace bytes at an existing release URL.
