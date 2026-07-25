# Hardware spike procedures S1-S11

## Shared protocol

These spikes settle load-bearing assumptions from `PLAN.md`. A product implementation, emulator-only
result, or anecdotal success does not replace the specified physical evidence.

For every run, record:

- Spike ID, UTC start/end, operator, build Git commit, app versions, protocol version, and whether the
  build is debug, Developer ID, or Android release signed.
- Exact phone manufacturer/model, retail firmware build, Android API/release, security patch, Google
  Play system update, and bootloader/root state.
- Exact Mac model, architecture, macOS build, signing Team ID, sandbox state, and `/Applications`
  location.
- Network/AP model, firmware, topology, isolation/multicast settings, and other radios involved.
- Preconditions, steps, expected result, actual result, raw system logs, redacted Eko diagnostics,
  generation/sequence bounds, and video/screenshots when UI timing matters.
- At least three fresh-state repetitions for timing/order-sensitive behavior. Reboot both endpoints
  between repetitions when persistence is part of the question.

Use synthetic notifications and fake OTP values. Evidence must not contain real messages, OTPs,
private keys, pairing tokens, nonces, full notification keys, SSIDs, or public IP addresses. Preserve
raw sensitive logs only in restricted storage when redaction would destroy the fact under test.

Name evidence directories with `SNN-YYYYMMDD-device-os-build`, place a short `result.md` at the root,
and store checksums for binary traces. A result is **pass**, **fail**, or **inconclusive**. Inconclusive
is not pass. Record the selected fallback before dependent feature work proceeds.

## S1: CDM association against a Mac BLE peripheral

### Question

Can a retail Android phone create a profile-less CDM association from a CoreBluetooth advertisement
using Eko's fixed service UUID despite macOS BLE address rotation, and does Android 16 presence remain
usable?

### Matrix and setup

- Pixel, Samsung, and Xiaomi retail devices spanning Android 14, 15, and 16. Include every available
  OEM/OS combination and identify gaps explicitly.
- macOS 14, 15, and 26 with Bluetooth allowed, plus one deny-then-grant run.
- A signed sandboxed Mac spike app advertising only the fixed Eko service UUID and a phone spike app
  using `BluetoothLeDeviceFilter` with a profile-less `AssociationRequest`.
- Location Services on for baseline, then off for the negative control. Do not grant app location or
  direct Bluetooth scan permissions.

### Procedure

1. Clear only the spike apps' prior associations and pairing state; capture the Android association
   inventory before testing.
2. Start the Mac advertisement and log CoreBluetooth state, advertisement start/stop, sleep/wake, and
   app relaunch without relying on the observable BLE address as identity.
3. Start CDM association on Android, select the advertised Eko device, approve the system dialog, and
   record association ID/profile/device metadata.
4. Register the API-appropriate presence observer and companion service. Record appeared/disappeared
   callbacks while moving the phone out of range and returning it.
5. Sleep/wake and reboot the Mac, toggle Mac Bluetooth, restart the phone, and repeat out-of-range
   cycles. Leave one run overnight to allow address rotation and idle behavior.
6. On Android 16, verify presence gates the companion power exemption as documented without treating
   it as part of notification pairing identity.
7. Turn Location Services off, clear the test association, and verify the picker fails with useful
   precheck guidance. Turn it on and recover.
8. Deny Mac Bluetooth, create the Wi-Fi access-point fallback association, and verify it grants an
   association but produces no BLE presence claim.
9. Remove the association and verify inventory/presence callbacks and supported listener-rebind
   trigger state. S2, not S1, decides redaction behavior.

### Pass and fallback

Pass requires successful association and repeatable presence return after address rotation,
sleep/wake, and reboot on the supported matrix, with no app scan/location permission. Record OEM/API
exceptions separately; do not average them away.

If association works but presence is unreliable, retain profile-less association for redaction trust
and make Android 16 BLE reliability explicitly optional/degraded. If BLE association fails, use the
Wi-Fi access-point association; accept loss of Android 16 presence-gated Doze exemption.

## S2: Sensitive-notification redaction trust and bind ordering

### Question

Does any non-revoked CDM association lift OTP redaction on Android 15/16 retail builds, and does the
supported unbind/rebind sequence refresh trust when association occurs after listener binding?

### Matrix and setup

- Retail Pixel, Samsung, and Xiaomi Android 15 and 16, with Enhanced notifications enabled.
- Profile-less BLE association from S1 and Wi-Fi association fallback. Include watch profile if S5
  permits it.
- A controlled source app that posts distinguishable synthetic OTP notifications in every relevant
  text field. Record source payload out of band without using a real credential.
- Eko spike listener logging callback receipt, exact system-redaction-resource match, bind events, and
  association changes without retaining the synthetic code in shared evidence.

### Procedure

1. Establish baseline with no association: grant notification access, bind the listener, post a new
   synthetic OTP, and determine whether Android delivers a placeholder or withholds the event.
2. Test **associate then bind** from clean app data: create association, grant/enable listener access,
   wait for `onListenerConnected`, then post a fresh OTP.
3. Test **bind then associate** from clean app data: bind first, verify baseline redaction, create the
   association while still bound, and post a second fresh OTP before repair.
4. Invoke instance `requestUnbind`, wait for `onListenerDisconnected`, invoke static
   `requestRebind(ComponentName)`, wait for `onListenerConnected`, and post a third fresh OTP.
5. Repeat the mutation while initially disconnected; call `requestRebind` directly and retest.
6. Revoke the last association while bound. Test before and after supported rebind to characterize the
   cache in both directions.
7. Repeat with two Mac pairings while retaining one association. Remove one pairing and prove Eko does
   not revoke the final association needed by the other.
8. Test notification-access off/on as the user fallback. Confirm no component disable/enable kick is
   used.
9. If CDM fails, apply the documented `RECEIVE_SENSITIVE_NOTIFICATIONS` app-op, rebind, and test. Reset
   it to default afterward.
10. As a separate last-resort run, disable Enhanced notifications system-wide, rebind, test, and
    restore the original setting.

### Pass and fallback

Pass requires unredacted synthetic text after association plus completed rebind for both orderings on
every supported retail build. It also requires Eko to detect the system placeholder and show repair,
not silently mirror it as content.

If profile-less trust differs by OEM, evaluate S5 watch profile. Otherwise retain supported rebind and
document app-op/Enhanced-notifications fallbacks, marking OTP as degraded on affected builds.

## S3: TLS 1.3 interoperability and certificate profile

### Question

Do bundled Conscrypt on API 26-28 and platform TLS on API 29-36 interoperate with Network.framework
on macOS 14-26 using mutually authenticated, self-signed P-256 certificates and exact DER pins?

### Matrix and setup

- Android API 26, 27, and 28 with the bundled Conscrypt provider; API 29, 30, 31, 33, 34, 35, and 36
  with the platform provider. Use physical devices for at least the oldest available and each retail
  Android 14/15/16 OEM; emulators fill API gaps.
- macOS 14, 15, and 26 on release-capable Macs.
- Candidate certificate profile with P-256 key, SHA-256 signature, fixed serial rules, explicit EKUs
  if selected, approximately 20-year validity, and exact DER fingerprint calculation.
- Packet metadata and endpoint TLS logs with payload/key logging disabled.

### Procedure

1. Generate identities once per install and record public certificate DER/hash. Restart apps and
   verify the same identity is retrieved.
2. Complete phone-client to Mac-server TLS 1.3 handshake with mutual certificate presentation and
   exact pin verification in both TrustManager and Network.framework verify blocks.
3. Verify negotiated version is TLS 1.3 and there is no TLS 1.2 fallback on API 26-28.
4. Exchange fragmented maximum-normal frames, a legal near-limit frame, and multiple coalesced frames.
   Verify partial-stream reads and no allocation before length validation.
5. Reject a changed leaf with the same key, same subject, trusted anchor, or same discovery name.
6. Reject a post-TLS `hello.device_id` that differs from the actual leaf fingerprint.
7. Verify pairing mode admits only its bounded unknown certificate state, while normal and unpair
   modes require their exact expected pins.
8. Test expired/not-yet-valid, wrong key usage, malformed DER, no client cert, unsupported curve, TLS
   downgrade, and oversized/zero frame length.
9. Test cert persistence across Android/Mac reboot and signed app upgrade. Certificate regeneration
   alone must be treated as changed identity.
10. Run 1,000 connect/close cycles and simultaneous multi-phone handshakes while checking resource
    caps and ten-second unauthenticated timeout.

### Pass and fallback

Pass requires TLS 1.3 and exact-pin behavior across the matrix with one documented certificate
profile and stable identity. If certificate extensions/validity fail on an OS, adjust the profile and
rerun all negative pin tests. If bundled Conscrypt cannot supply reliable TLS 1.3 on API 26-28, raise
minimum SDK to 29 rather than adding a TLS downgrade. Raw-public-key pinning is the final design
fallback and requires a new reviewed protocol decision.

## S4: LSUIElement notifications and pasteboard behavior

### Question

Can a signed `/Applications` `LSUIElement` app request and deliver UserNotifications, execute the
authenticated Copy code action without unwanted activation, and poll pasteboard `changeCount` on
macOS 26 without a read alert?

### Matrix and setup

- Developer ID signed, hardened, sandboxed spike app in `/Applications` on macOS 14, 15, and 26.
- Fresh macOS users or VM snapshots for notification consent. Test locked/unlocked sessions and each
  notification preview setting.
- Synthetic codes only. Record app activation, key window, pasteboard change count, action callback,
  and privacy prompts.

### Procedure

1. Request provisional authorization and post a quiet notification from the accessory app.
2. Exercise the explicit authorization upgrade, deny, grant-later, and revoke-after-grant paths.
3. Post normal mirrored and OTP-category notifications while the panel is closed and while another
   app is active.
4. Invoke the non-foreground, authentication-required Copy code action unlocked and locked. Verify
   authentication, callback delivery, pasteboard write, and no unnecessary app activation.
5. Confirm notification `userInfo` contains only stable lookup identifiers, not another OTP copy.
6. Write concealed string data, capture `changeCount`, and poll only that count until two minutes.
   Verify no macOS 26 pasteboard-read alert.
7. Modify the clipboard in another app before expiry and verify Eko does not clear it. Leave unchanged
   and verify Eko clears its code.
8. Test banner, alert, Notification Center, Do Not Disturb/Focus, app notification denial, and
   delivered-notification removal after phone dismissal.
9. Verify replay creates one summary and no old-event banner storm.

### Pass and fallback

Pass requires reliable signed-app notification delivery/action handling and alert-free `changeCount`
use on the supported matrix. If `LSUIElement` delivery fails, use Eko-owned `NSPanel` toasts after an
accessibility/security review. If `changeCount` causes privacy alerts, remove auto-clear rather than
reading clipboard contents.

## S5: Watch-profile CDM alternative

### Question

Does `DEVICE_PROFILE_WATCH` grant the `COMPANION_DEVICE_WATCH` role and sensitive-notification
permission on retail builds, and is the system consent language acceptable for pairing a Mac?

### Matrix and setup

Use S1's Pixel/Samsung/Xiaomi Android 14/15/16 matrix. Declare only the normal
`REQUEST_COMPANION_PROFILE_WATCH` permission needed for this isolated build. Capture system dialog
text/screenshots for each locale used in evaluation and role/app-op state before/after association.

### Procedure

1. From clean app data, request a watch-profile association against the Mac BLE advertisement.
2. Record every system disclosure and whether the Mac is misleadingly represented as a watch.
3. After approval, inspect association profile, assigned role, package permissions/app-ops, and
   presence behavior.
4. Run S2's associate-before-bind and bind-before-associate redaction cases, including rebind.
5. Reboot, upgrade the app, revoke the association, and verify role/permission cleanup.
6. Compare user completion and comprehension with profile-less association during S7.
7. Verify rejection/cancellation leaves no partial role or association.

### Pass and fallback

Technical pass requires role/permission and unredacted callback behavior on all supported retail
builds with clean revocation. Product pass additionally requires consent text that does not deceive or
confuse users. If either fails, use profile-less CDM as the primary path.

## S6: Developer ID sandbox Keychain identity

### Question

Does a Developer ID signed, sandboxed app reliably create and retrieve a non-exportable,
non-synchronizable P-256 identity in the data-protection Keychain without an unavailable access-group
or provisioning-profile dependency?

### Matrix and setup

Test macOS 14, 15, and 26 on clean users with the production bundle ID/Team ID and candidate
entitlements. Use a Keychain diagnostic build that reports status codes and public hashes but never
private key bytes.

### Procedure

1. Create the key with data-protection Keychain enabled, permanent storage, ThisDeviceOnly
   accessibility, non-synchronizable attributes, and no export path.
2. Build the self-signed certificate, store it with the matching key, query `SecIdentity`, and bridge
   it to Network.framework.
3. Relaunch, reboot, lock/unlock, sleep/wake, and verify the identical certificate DER/device ID.
4. Upgrade over a prior signed build and verify identity persistence. Test launch before and after
   login-item approval.
5. Attempt unauthorized export/synchronization and verify failure. Confirm no identity appears in
   iCloud Keychain on another Mac.
6. Test duplicate app copies without using them concurrently; verify documentation keeps one copy in
   `/Applications` and no second identity is silently selected.
7. Remove only the test app's Keychain items, relaunch, and verify Eko reports identity change/new
   pairing rather than pretending peers still trust it.
8. Inspect signing requirements and access-group behavior with release entitlements, not an Xcode
   development-only profile.

### Pass and fallback

Pass requires stable retrieval and Network.framework use across update/reboot with the intended
security attributes and no provisioning-profile-only dependency. If blocked, use a separately
reviewed encrypted sandbox file whose wrapping key remains in an available Keychain class; do not
fall back to plaintext key files.

## S7: Sideload onboarding friction

### Question

Can target non-technical users complete unknown-app installation, Android 13 restricted settings,
pairing/CDM, notification access, and the test round trip without unsafe workarounds?

### Participants and setup

Recruit at least three participants who have not used the development build. Cover browser/GitHub,
file manager, and Obtainium paths across stock Android and one OEM skin. Obtain informed consent for
screen/audio recording and prohibit real notification content during the study.

### Procedure

1. Give only the published release page and the normal Mac wizard. Do not pre-enable permissions.
2. Ask the participant to install and pair while thinking aloud. The observer may intervene only for
   safety; record every intervention and the screen where progress stopped.
3. Exercise checksum/signing explanation, install-source permission, `/Applications` move, pairing
   code comparison, Location Services precheck, CDM dialog, restricted settings, notification access,
   ordinary notifications, optional battery exemption, and test notification.
4. Ask the participant what notification access, the association, and each degraded permission means.
5. Ask them to find pause, resume, diagnostics, unpair, and update instructions without coaching.
6. Repeat an update through the selected channel and verify they do not uninstall first.
7. End by removing test pairings/data and restoring install-source/Developer options state.

### Pass and fallback

Pass requires every participant to complete a safe round trip without an undisclosed critical
intervention, correctly reject a deliberately mismatched code scenario, and understand that Eko reads
notification content locally. Record time and drop-off points; do not define success from average
time alone. If paths fail, prefer Obtainium-first guidance, installer-specific screenshots, and
step-by-step Mac wizard remediation, then rerun with new participants.

## S8: OEM lifecycle evidence and false alarms

### Question

Are Eko's available signals sufficient to show actionable reliability help without claiming an OEM
kill from normal silence?

### Matrix and setup

Use Pixel plus Samsung, Xiaomi, Huawei, and OnePlus where available. Prepare a synthetic notification
source, a Mac ground-truth collector, controlled network toggles, and builds that expose listener
transitions, `ApplicationExitInfo`, foreground-service start failures, writer overflow, and committed
backlog growth.

### Procedure

1. Establish a 24-hour quiet negative control with no source notifications. Eko must not assert a
   kill or capture gap from silence.
2. Induce ordinary process kill, low-memory kill, Settings force-stop, Android Task Manager Stop,
   OEM optimizer kill, phone reboot, listener access revoke, Wi-Fi loss, Mac sleep, and source-app
   silence as separate labeled cases.
3. For each case, capture the immediate Mac state and the next phone-start evidence. Verify Task
   Manager Stop becomes paused only after `REASON_USER_REQUESTED` is observed on next start.
4. Generate committed events while network-only failures occur and verify backlog growth/replay does
   not trigger an OEM-kill claim.
5. Force bounded writer rejection and listener disconnect in test builds. Verify suspected capture
   gaps carry evidence/time/confidence but no fabricated missing count.
6. Apply OEM remediation and repeat the causative case. Record whether the signal disappears without
   suppressing unrelated diagnostics.
7. Have reviewers classify prompts blind to the induced condition; calculate false-positive and
   missed-evidence cases per signal, not from notification frequency.

### Pass and fallback

Pass requires no alarm during silence/network-only controls, accurate neutral wording for ambiguous
disconnects, and OEM-specific prompts only from concrete evidence. If signals are not discriminative,
show factual diagnostics and generic recovery rather than asserting an OEM kill. Tune prompts only
from consented beta diagnostics.

## S9: Battery budget

### Question

Is Eko's attributed drain below 2 percent per 24 hours on a Pixel-class phone with the 25-second
awake heartbeat target, and what is the incremental cost of Android 16 BLE presence on one OEM phone?

### Matrix and controls

- Current Pixel plus at least one Samsung or Xiaomi retail device; include Android 16 for presence.
- Two matched 24-hour runs per configuration: baseline without Eko activity and Eko paired/idle with
  controlled synthetic traffic. Repeat with BLE presence off/on on Android 16.
- Stable firmware, signal strength, AP, battery health, screen-use script, ambient temperature,
  charging state, source-traffic count, and other app sync. Disable adaptive changes that would make
  paired runs incomparable, and document every deviation.

### Procedure

1. Charge to the same starting range, unplug, let temperature stabilize, and reset BatteryStats using
   the supported test workflow.
2. Record battery capacity/health and capture a baseline bugreport. Do not use percentage drop alone
   on devices whose reported level is heavily rounded.
3. Run the same scripted screen-on/off, Wi-Fi, Mac sleep, and synthetic notification schedule for 24
   hours. Include normal overnight idle and reconnect.
4. Capture `dumpsys batterystats`, a full bugreport, Eko connection/heartbeat counts, wakeups, network
   bytes, foreground-service duration, BLE presence state, thermal events, and final battery level.
5. Analyze with Battery Historian and Android's per-UID attribution. Separate Eko from screen, weak
   radio, source app, and test automation costs.
6. Swap baseline/configuration order on the repeat day to reduce day-order bias.
7. Repeat after proposed screen-off/idle heartbeat relaxation if any configuration exceeds budget.
8. Verify latency/replay behavior alongside drain; an optimization cannot silently weaken committed
   event recovery or gap reporting.

### Pass and fallback

Pass requires reproducible Eko-attributed drain below 2 percent per day on Pixel and an accepted,
documented OEM/presence result without unexplained thermal/radio confounding. If missed, relax ping
cadence while screen-off/idle, retain immediate wake/network triggers, explain latency tradeoffs, and
keep BLE presence opt-in. Rerun full 24-hour comparisons; do not extrapolate from a short test.

## S10: SQLite/Room durability contract

### Question

Is every writable event-store connection actually WAL plus `synchronous=FULL`, does the durable
high-water never regress under software/storage faults, and do externally acknowledged commits
survive abrupt physical power loss?

### Matrix and rig

- Every supported Android API represented in instrumentation, with physical devices covering old and
  current storage stacks and at least one retail OEM.
- Abrupt power-cut/reset-capable hardware controlled independently from the phone. A normal `adb
  reboot`, emulator stop, process kill, or battery UI shutdown does not prove flash power-loss safety.
- An external controller that sends uniquely numbered callback inputs, receives a post-transaction
  commit receipt, records receipts durably outside the phone, and cuts power at randomized points.
- Test database integrity checker, reset journal, generation observer, and immutable external event
  ledger.

### Procedure

1. On every writable connection/open path, query and record `journal_mode` and `synchronous`; fail
   capture before the first callback if effective state is not WAL/FULL.
2. Exercise callback transactions that increment metadata high-water, insert outbox, and mutate active
   state atomically. Kill the process before transaction, during transaction, after commit before
   receipt, and after receipt.
3. Inject disk-full, I/O error, database-corruption, migration interruption, WAL/checkpoint, and
   identity-store reset-journal interruption cases with supported lab mechanisms.
4. For physical tests, let the external rig choose an unpredictable cut point over thousands of
   cycles. After reboot/unlock, compare all externally received commit receipts with outbox or
   authorized deletion evidence and verify `last_assigned_seq` never decreases.
5. Cut power during generation reset at each journal stage. Startup must idempotently finish with old
   generation retired, fresh generation empty, pairings rehydrated at zero/one, and incremented epoch.
6. Verify old rows are never copied/relabelled into the new generation and Mac history remains
   namespaced.
7. Run multi-pair retention/ACK pruning under fault injection. No row may be physically deleted until
   every pairing has an ACK or explicit floor/gap authorization.
8. Run SQLite integrity checks and compare active materialization against committed event ledger after
   every recovery.

### Pass and fallback

Pass requires WAL/FULL readback on all supported APIs, no loss of any externally acknowledged commit,
no high-water regression, atomic active/outbox state, and idempotent reset recovery across the physical
fault campaign. Storage hardware can still violate fsync; state that residual risk plainly.

If Room cannot enforce the connection contract, own/configure the single write connection directly.
If physical tests lose acknowledged commits, weaken the published durability guarantee before release
or change the storage design and rerun; emulator/process tests cannot waive this gate.

## S11: Managed-profile behavior

### Question

Does Android ignore an NLS installed inside a managed profile, when may a personal-profile listener
receive work notifications, and which work app labels/icons are inaccessible under policy?

### Matrix and setup

Use TestDPC plus at least one physical enterprise enrollment on Pixel and one OEM device. Cover Android
14-16 and policies that allow and disallow cross-profile notification listeners. Use distinct
synthetic personal/work packages and messages with no organizational data.

### Procedure

1. Install the spike app only in the managed profile, attempt notification-access setup, and record
   settings visibility, bind callbacks, and source notifications. Verify product onboarding refuses
   this configuration rather than promising capture.
2. Install Eko in the personal profile. Post personal notifications and establish baseline.
3. Under a DPC policy allowing cross-profile notification listeners, post/update/remove work
   notifications and record callback user handle, package, label/icon resolution, key handling, and
   dismissal behavior.
4. Change policy to disallow cross-profile listeners and repeat. Absence of callbacks must be reported
   as policy-dependent behavior, not a listener-stall proof.
5. Exercise identical package names in both profiles and verify all rules/materialized state are keyed
   by `(package, user)`.
6. Deny cross-profile package metadata lookup while permitting notification delivery. Verify package
   name fallback and no crash/content mix-up.
7. Pause/lock/remove the work profile and reconcile active state. Confirm suspected-gap wording only
   when actual listener/process evidence exists.
8. Reboot, update Eko, and repeat the permitted path. Remove the managed profile and verify stale work
   labels/rules do not attach to personal notifications.

### Pass and fallback

Pass requires reliable refusal of in-profile setup, correct personal capture, policy-accurate best-
effort work capture, `(package, user)` isolation, and package-name fallback when labels/icons are
denied. If OEM policy behavior is inconsistent, keep work capture explicitly best effort and never
claim organizational policy can be bypassed.

## Decision review

After each spike, a reviewer not operating the run must verify that the evidence supports the result,
negative controls ran, private data was removed, and the fallback matches the observed failure. Update
dependent product requirements and these procedures together. Do not close a spike because the happy
path worked once.
