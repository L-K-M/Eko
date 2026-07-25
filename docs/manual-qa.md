# Manual QA

## Purpose and evidence

Run this checklist against a release candidate built with production signing settings. Record the
build identifiers, APK certificate digest, Mac Team ID, protocol version, database schema versions,
device/OS versions, network topology, and the tester for every run.

Use synthetic notifications with unique sequence labels and fake OTPs. Never use a live banking,
login, or recovery credential. Save screenshots only after checking them for message content,
fingerprints, hostnames, and QR tokens.

A pass requires both visible behavior and durable-state evidence where relevant. "It appeared once"
is not sufficient for replay, retention, signing, TCC, or lifecycle cases.

## Minimum release matrix

| Area | Required coverage |
|---|---|
| Android | Retail Android 14, 15, and 16; Pixel plus current Samsung and Xiaomi devices; one Huawei or OnePlus reliability pass when available |
| Legacy Android | API 26-28 TLS/Conscrypt and basic install on emulator or retained hardware; API 29+ platform TLS boundary |
| macOS | macOS 14, 15, and 26 on real Macs or release-equivalent VMs where hardware behavior is not under test |
| Install source | Browser/GitHub APK, file manager APK, and Obtainium update path |
| Profiles | Personal profile and TestDPC-managed work profile on physical enterprise-capable hardware |
| Network | Normal LAN, multicast blocked, AP isolation, port collision, Wi-Fi loss, Mac sleep, and clock skew |
| Accessibility | Keyboard-only, VoiceOver, non-color state, Reduce Motion, increased text/display size, and increased contrast |

The physical hardware spike gates in [Hardware spikes S1-S11](hardware-spikes.md) are not replaced by
this regression checklist.

## Fresh installation and pairing

- [ ] Install the notarized Mac app into `/Applications`; verify no Gatekeeper bypass instructions
  are needed.
- [ ] Verify launch-at-login registration and the `.requiresApproval` path from System Settings.
- [ ] Install the APK from each required source. Confirm unknown-app permission is scoped to that
  source and can be turned off afterward.
- [ ] On Android 13+, reproduce a restricted sideload and verify **Allow restricted settings** help
  reaches Eko App info before notification access.
- [ ] Verify setup refuses an install running in a managed profile and explains personal-profile
  installation.
- [ ] Pair by QR. Confirm token single use, expiry, and no acceptance after pairing mode closes.
- [ ] Pair by discovery/manual entry. Confirm one changed verification-code character causes the
  tester to reject and no pairing row survives as confirmed.
- [ ] Interrupt each pairing phase, reconnect, and verify an unexpired pending attempt resumes
  idempotently while an expired attempt does not.
- [ ] Verify pre-pair history is not disclosed to the new Mac.
- [ ] Verify CDM association creation with Location Services on and useful guidance with it off.
- [ ] Verify Wi-Fi access-point fallback when Mac Bluetooth is denied.
- [ ] Grant notification access, ordinary notifications, and optional battery exemption separately;
  verify every checklist state updates after returning from Settings.
- [ ] Send the synthetic setup notification and require round-trip confirmation.

## macOS TCC and system integration

Local Network permission cannot be reliably reset by deleting preferences or reinstalling the same
bundle. Use a clean VM snapshot or fresh macOS user for each first-prompt decision. Test signed builds
from `/Applications`; unsigned/ad-hoc locations do not provide release-equivalent notification or TCC
behavior. Do not edit the TCC database manually as a release test.

### Local Network

- [ ] From a clean consent state, trigger Bonjour publish/browse and verify the usage string and
  responsible Eko process identity.
- [ ] Deny access. Verify Eko reports `Local Network access is off - discovery disabled; direct
  connections still work` rather than a fatal listener error.
- [ ] With access denied, pair/direct-connect using QR/manual details and verify the phone's incoming
  TLS connection and replay still work.
- [ ] Grant access in **Privacy & Security > Local Network** and verify Bonjour recovers without app
  reinstall or a busy retry loop.
- [ ] Revoke after grant and verify `.waiting`, policy-denied handling, and direct-path continuity.

### Bluetooth

- [ ] Grant Bluetooth and verify Eko advertises the fixed service used by Android CDM.
- [ ] Deny Bluetooth and verify mirroring remains available, pairing offers Wi-Fi association, and the
  UI labels only presence/reliability as degraded.
- [ ] Grant later and verify advertising recovers without creating duplicate pairing identity.

### Notifications and other privacy prompts

- [ ] Verify provisional notification authorization, explicit upgrade guidance, a normal mirrored
  banner, and a backlog summary banner.
- [ ] Trigger **Copy code** while the Mac is locked and unlocked. Confirm the action requires
  authentication and does not unnecessarily activate the accessory app.
- [ ] Verify denied notification authorization leaves panel history usable.
- [ ] Verify Eko does not request Accessibility, Contacts, Full Disk Access, Screen Recording,
  Microphone, Input Monitoring, or Location permission in v1.
- [ ] On macOS 26, test pasteboard `changeCount` and two-minute auto-clear with no clipboard-read
  privacy alert. Confirm Eko clears only when the change count is unchanged.

## Notification behavior

- [ ] Post, update several times, and remove one notification. Verify every committed intermediate
  update has its own sequence and the final Mac materialized state is correct.
- [ ] Test title, text, big text, subtext, info, summary, text lines, and MessagingStyle fields without
  flattening them on the phone.
- [ ] Verify group summaries do not produce OTP banners and a child/summary duplicate code produces
  one banner within the ten-minute device/code window.
- [ ] Verify ongoing and Eko's own foreground-service notifications are skipped by default.
- [ ] Verify phone-side per-app disable prevents future capture while Mac mute still receives/stores
  events without banners.
- [ ] Verify Android DND causes silent panel delivery by default and does not discard the event.
- [ ] Dismiss from the Mac and confirm the resulting Android removal event. Dismiss on the phone and
  confirm the delivered Mac banner retracts.
- [ ] Verify a stale fetch response cannot overwrite a newer sequenced state for the same key.
- [ ] Exercise work and personal copies of the same package and verify `(package, user)` isolation.

## OTP and redaction

- [ ] On Android 15/16 with Enhanced notifications enabled, test association-before-bind and
  bind-before-association. The latter must remain redacted until supported rebind completes.
- [ ] Revoke the final association and confirm Eko surfaces the redaction repair state rather than
  forwarding the placeholder as useful text.
- [ ] Run listener repair and verify unbind, disconnect, rebind, connect ordering.
- [ ] Exercise the full shared OTP corpus, including multilingual digits, Swiss currency/years,
  domain-bound codes, SMS Retriever hashes, grouped digits, group summaries, and intermediate
  updates.
- [ ] Confirm replayed backlog never emits one native banner per old OTP; one summary is allowed.
- [ ] Confirm banking-style TANs are never auto-copied and all copied codes retain original message
  context in the panel.

## Store-and-forward and multi-device recovery

Use at least two Macs paired to one phone and two phones paired to one Mac.

- [ ] Withhold acknowledgements from one Mac while the other stays current. Verify the shared outbox
  retains rows needed by either pairing and independently advances each cursor.
- [ ] Force the slow Mac over a small test retention cap. Verify an exact gap is committed for that
  Mac before physical deletion and the fast Mac loses no needed row.
- [ ] Disconnect mid-frame and mid-backlog, reconnect, and verify event-or-gap coverage through the
  final cursor with no duplicate database rows.
- [ ] Lose an acknowledgement after the Mac commit. Verify replay/idempotent ingest and later
  cumulative acknowledgement.
- [ ] Sleep/wake the Mac, toggle phone Wi-Fi, change IP addresses, block multicast, and restart both
  endpoints. Verify committed rows replay from the durable cursor.
- [ ] Restore a deliberately older Mac test database. Verify `peer_cursor_regressed` covers only the
  unavailable interval before replay resumes at the floor.
- [ ] Replace the phone test database under the reset journal. Verify a new generation, sequence reset,
  transition marker, old history namespace, and no cross-generation key comparison.
- [ ] Present a welcome cursor above phone high-water. Verify journaled generation reset rather than
  silent cursor clamping.
- [ ] Race old and new connections. Only the strictly higher persistent epoch may win.
- [ ] Leave both endpoints apart beyond retention. Verify definitive gaps plus active-snapshot
  reconciliation, and no fabricated count for suspected capture gaps.

## Android lifecycle and OEM behavior

- [ ] Kill the ordinary process and verify committed rows survive, NLS normally rebinds, and active
  state reconciles.
- [ ] Use Settings **Force stop**. Verify no claim of background recovery until the user opens Eko.
- [ ] Use Android Task Manager **Stop**. On next launch, verify `REASON_USER_REQUESTED`, persisted
  paused state, explanation, and explicit Resume requirement.
- [ ] Swipe away the visible foreground-service notification on a supported release. Verify service
  behavior matches the OS and Eko does not misreport a stop.
- [ ] Enter Doze/app standby using supported test controls, then wake. Verify timing deadlines are not
  presented as wall-clock guarantees and replay heals committed events.
- [ ] Reboot and unlock. Verify connection epoch and event high-water never regress.
- [ ] Apply each detected Samsung/Xiaomi/Huawei/OnePlus guide and verify links, current menu wording,
  and that prompts arise only from concrete health evidence.
- [ ] Complete the 24-hour battery gate rather than extrapolating from a short run.

## Accessibility

### Keyboard-only

- [ ] Open and close the panel without a pointer using the configured shortcut and standard macOS
  keyboard navigation.
- [ ] Move through every device chip, filter, notification row, OTP action, settings control, pairing
  step, warning, and fix-it link with a visible focus indicator.
- [ ] Activate Copy, Copy code, Dismiss, Mute, Add phone, Confirm, Reject, and unpair without focus
  loss or an unexpected panel close.
- [ ] Verify focus returns predictably after a row disappears and after settings closes.
- [ ] Verify no shortcut uses Finder's Option-Command-V default; detect and warn about known
  collisions.

### VoiceOver

- [ ] Use VoiceOver Quick Nav and standard navigation from the status item through the panel.
- [ ] Confirm device chips announce name, connected/reconnecting/disconnected state, and last-seen
  context without relying on color.
- [ ] Confirm rows announce source app, phone, time, replay/gap status, message summary, and available
  actions in a useful order.
- [ ] Confirm OTP code characters are understandable, Copy code has a distinct label, and the source
  message remains available.
- [ ] Confirm definitive retention gaps and suspected capture gaps have different labels and that
  suspected gaps do not announce a missing count.
- [ ] Confirm pairing codes and mismatch/reject controls are not exposed as unlabeled images.

### Visual and motion settings

- [ ] Check light/dark mode, Increase Contrast, Reduce Transparency, and color filters. State must use
  shape/text as well as color.
- [ ] Enable Reduce Motion and verify status pulses/progress transitions become static or minimal.
- [ ] Increase macOS display/text size and Android font/display size. Content and actions must reflow
  without clipping the OTP or verification code.
- [ ] Verify 200 percent zoom screenshots and narrow panel height preserve scrolling and focus.

## Diagnostics and privacy

- [ ] Seed synthetic canaries in every notification field, device name, app label, hostname, SSID,
  notification key, and pairing display data.
- [ ] Export default diagnostics on both endpoints. Inspect every archive member and verify the
  canaries and raw stable identifiers are absent.
- [ ] Verify per-export pseudonyms correlate records within one export but differ across two exports.
- [ ] Enable content for one export, review its warning/scope, then start another export and verify
  content is off again.
- [ ] Verify private keys, QR tokens, nonces, full certificates, Wi-Fi credentials, and clipboard
  history are never exported.
- [ ] Delete history and unpair online/offline. Confirm normal traffic is blocked immediately and a
  tombstoned session accepts only unpair exchange.
- [ ] Verify Android backup extraction rules omit outbox and identity files; a device transfer creates
  a new identity rather than a clone.

## Release smoke and result

- [ ] Upgrade from the previous public Android and Mac releases without identity, pairing, grant,
  association, cursor, or history loss.
- [ ] Fresh-install both release artifacts and complete setup without development tools.
- [ ] Verify checksums, signatures, notarization ticket, entitlements, package ID, version, and update
  metadata match the release record.
- [ ] Run the deterministic tool harness and automated suites with recorded seed/counts.
- [ ] Record every failure with expected/actual behavior, generation/sequence bounds, redacted
  diagnostics, and disposition. A release blocker cannot be waived solely because a retry passed.
