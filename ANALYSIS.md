# Eko — analysis and open work

The standing list of what is wrong with Eko, what is missing from it, and what would make it
good. It is the merge of the review in [`opus.md`](opus.md) with what has since been acted on:
anything addressed is recorded in the ledger below and struck from the body, so the body is
always *remaining* work.

`opus.md` is kept as the point-in-time review, with its evidence and its argument. This file is
the working document. When something lands, move it from the body to the ledger rather than
deleting it — the ledger is how the next person knows a question was already answered.

Severity bands: **critical** (data loss, hangs, unusable) · **high** (a user hits it in the
first hour) · **medium** (real, bounded) · **low** (polish, tech debt) · **idea** (opinion).
**[V]** means verified by running a toolchain here; **[S]** means source-verified only.

---

## Ledger — addressed, in review

None of these are merged yet. Repository CI could not run while they were opened (see
[Working notes](#working-notes)), so every "verified" claim below is a local run.

| PR | What it closes |
| --- | --- |
| [#17](https://github.com/L-K-M/Eko/pull/17) Android transport hot path | Non-atomic `TransportRuntime.update`; foreground-service notification re-posted per mirrored event; reconnect backoff reset on every mDNS sighting; `startForeground` failure crashing the process; `Mac(s)` → `<plurals>`; dead `SDK_INT < 26` guard |
| [#18](https://github.com/L-K-M/Eko/pull/18) Capture durability | Queued commits discarded when the listener is torn down (**the notification-loss bug**); `removeCallbacks(::enqueueReconciliation)` removing nothing, and the phantom Diagnostics counters it produced; per-notification `Resources.getIdentifier` for the redaction marker |
| [#19](https://github.com/L-K-M/Eko/pull/19) ViewModel hot path | N+1 `pairingRows()` per peer per captured notification; Home recomputing at the capture rate; uncaught store failure killing the app on launch; five binder round-trips on the main thread per resume |
| [#20](https://github.com/L-K-M/Eko/pull/20) Android UI | Landing on the setup checklist every launch; the invisible QR reticle, missing `BackHandler` and missing insets; nothing surviving rotation; the Mac name starved to one glyph per line; fake-button status chip; unlabelled switch rows; unpair dialog overflow and inverted hierarchy; frozen diagnostics timestamps; dark-mode launch flash; off-centre launcher icon with no monochrome layer |
| [#21](https://github.com/L-K-M/Eko/pull/21) macOS menu & chrome | **No main menu** — app could not be quit, ⌘C/⌘V/⌘Q dead; opaque panel defeating `.ultraThinMaterial`; traffic lights over the logo; `.popUpMenu` above the Settings window; status-item redraw storm; the "code available" badge that never expired; no Escape, no highlight, no right-click menu |
| [#22](https://github.com/L-K-M/Eko/pull/22) macOS panel performance | **A synchronous main-thread DB read per committed event**; `focus` blocking the panel on a 500-row query; three `pool.write`s on the main actor behind a 5 s busy timeout; the feed observation running while the panel is hidden; the one-shot diagnostics content toggle that wasn't |
| [#23](https://github.com/L-K-M/Eko/pull/23) CI | `:core`'s nine test classes never ran — including the shared protocol vectors and the pinning test |

Also resolved independently, on `main` in [#4](https://github.com/L-K-M/Eko/pull/4): CI and
release workflows exist; `scripts/check-protocol.py` validates schemas and embedded scenario
frames; Dependabot covers Gradle and Swift; README/AGENTS no longer claim pre-scaffold status.

**Partially addressed — the remainder is still open below.** #20 fixed the Android launcher
icon and window background but not the wider brand/design-token work ([D-01](#d-01),
[D-02](#d-02)). #22 suspended the feed observation but did not add the missing index or stop
the `device` table being dirtied per event ([P-01](#p-01)). #18 cached the redaction marker but
not app labels, and left extraction on the listener's main thread ([P-02](#p-02)).

---

## 1. Correctness

### macOS core

<a id="b-01"></a>
**B-01 · `confirmPairing` leaves the superseded generation un-retired** — `high` [S]
`EkoStore.swift:440,558`, `SessionManager.swift:141`

`beginSession` treats a generation change as a hard boundary — retire the old generation,
deactivate its notifications. `confirmPairing` performs the same generation change and does
neither. Reachable through `(.revoked, .pair)`: a device reaches `revoked_pending` with history
intact via `requestUnpair` on a live session, and re-pairing from the phone commits G2 while G1's
rows survive un-retired.

Two consequences. G1's rows stay `is_active = 1` forever, so the panel shows dead notifications
as live and "Dismiss on phone" targets a dead generation. And G1 is not in `retired_generation`,
so a later `beginSession` announcing G1 passes the retired check, sets `cursor = 0`, and the first
`ingestEvent` at seq 1 hits the surviving `(device, G1, 1)` composite primary key — **a hard throw
out of `runNormalLoop` on every reconnect, with no recovery short of "forget device".**

*Fix:* make `confirmPairing` do the same boundary work, and make `beginSession` assert on reset
that no rows exist for the incoming `(device, generation)` so a rollback fails loudly at admission
rather than wedging on first insert.

**B-02 · `AckAccumulator.flush` is reentrant** — `medium` [S] · `SessionManager.swift:993,1013`
`lastSent` is mutated *after* `await transport.send`. Actor reentrancy lets the 1-second timer and
the 20-position threshold both pass the `highestCommitted > lastSent` guard while a send is in
flight; if the later flush carries a higher sequence and completes first, the earlier one writes
the *lower* value back and the next flush re-sends an already-acknowledged sequence. Separately,
the early `return` never resets `positionsSinceAck`, so past 20 the counter stays over threshold
and `committed` flushes on every event — quietly defeating the batching design during replay.

**B-03 · Fetch responses that lose a race with a live removal strand the row** — `medium` [S]
`EkoStore.swift:949,1005,1085,1717`
A key marked `body_complete = 0` pending fetch is hidden from the feed. `applyFetchEvent` bails on
`guard stateSequence >= existingState`. If a `removed` event arrives before the fetch response, the
row is stranded at `body_complete = 0` **forever** — never in the feed, never in per-app settings,
never repaired. A notification silently lost from history even though the event stream committed
and ACKed cleanly.

**B-04 · Accumulated active-snapshot has no ceiling** — `medium` [S] · `SessionStateMachine.swift:149`
Per-chunk entries are capped; the *number* of chunks is not, and `final` is peer-controlled. With
8 KiB keys, a phone that never finalises grows the array and the `Set` until the process dies.
Needs a documented ceiling in `protocol.md` §9 as well as the check.

**B-05 · `NWListener .waiting` never resumes the start continuation** — `low` [S] · `TLSListener.swift:80`
`.waiting` is reported but not resumed, and `NWListener` can sit there indefinitely (port held,
Local Network not granted). `startWithPortFallback` then never reaches its `catch`, the `.any`-port
fallback never runs, and the task hangs — a permanently "starting" listener with no error.

**B-06 · A paired peer can flip another device's UI state to failed** — `low` [S] · `SessionManager.swift:96,193`
`claimedDeviceID = hello.deviceID` is assigned *before* the fingerprint check, and the catch block
reports that unverified claim through `connectionStateChanged` into `AppModel.connectionStates`.
One-line fix: assign after the check, or derive it from the peer certificate.

**B-07 · Event receipts grow unbounded within a generation** — `low` [S] · `EkoStore.swift:1483,1516`
`prune` strips payloads but never deletes rows for the current generation, because the duplicate
check needs them. Sound reasoning; the effect is a `WITHOUT ROWID` table growing monotonically for
the life of a pairing, with `notification_key` up to 8 KiB per row. Bound the window below
max(Mac retention, the phone's 48 h/2 000 outbox) and record one gap span for the deleted range.

### Android core

<a id="b-08"></a>
**B-08 · Swiping from Recents permanently pauses forwarding** — `high` [S] · `EkoApplication.kt:129-154`
`REASON_USER_REQUESTED` is treated as a deliberate stop, but the AOSP constant also covers *removing
the app from Recents*. That gesture silently and permanently disables the product's only function,
and contradicts the transport manifest's `android:stopWithTask="false"`. Most reachable during
onboarding, before any foreground service holds the process up. Needs corroborating evidence (an
"fgs active" marker, or `getImportance()`) before latching — and a visible, dismissible banner with
a Resume button either way (see [F-05](#f-05)).

**B-09 · Per-app "include ongoing" cannot work on Android 13+** — `medium` [S]
`capture/AndroidManifest.xml:12`
`default_filter_types="conversations|alerting|silent"` omits `ongoing`, which on API 33+ means those
notifications are never delivered and never appear in `getActiveNotifications()`. The per-app toggle
that exists to admit them is therefore inert on 33+ and functional on 26–32, with no public API to
widen the filter from the app. Either add `ongoing` and rely on the app-side `shouldForward` filter,
or hide the switch on 33+ and explain via `getCurrentListenerFilter()`.

<a id="b-10"></a>
**B-10 · A stalled TCP write disables the heartbeat's own liveness check** — `medium` [S]
`TlsConnector.kt:67`, `NormalPeerSession.kt:106`
`soTimeout = 0` and the pong deadline is armed *after* `outbound.send` returns. `OutputStream.write`
has no timeout in Java, so a peer that stops draining wedges the session permanently — reader
blocked in a timeout-less read, live stream blocked behind the same actor, nothing mirrored until OS
TCP keepalive (2 h). `ConnectionService` also never cancels a running session on network change.
Arm the watchdog *before* the send, and observe `networkMonitor.networks` from the peer job.

**B-11 · `peerJobs.computeIfAbsent` can recursively mutate the same key** — `low` [S]
`ConnectionService.kt:86`
`invokeOnCompletion` runs synchronously when the job is already complete, so `peerJobs.remove` can
run inside `computeIfAbsent`'s mapping function for the locked key. `ConcurrentHashMap` forbids
this; against the installed `ReservationNode`, `replaceNode` spins unbounded on an IO thread.
`reconcileJobs` is also entered concurrently from two coroutines with no mutual exclusion.

### Protocol / interop

**B-12 · The Mac imposes an undocumented 30 s deadline inside the 300 s pairing window** — `high` [S]
`protocol.md:307` defines one deadline; the phone honours it and leaves its confirm sheet up for the
full 300 s. The Mac blocks unboundedly on its *own* approval sheet and then applies a fixed 30 s
per-frame deadline to the phone's `pair_result`. A user who takes 40 s to press Confirm on the phone
gets a failure the protocol says cannot happen.

<a id="b-13"></a>
**B-13 · The phone ignores `error{unpaired}` / `error{stale_generation}`** — `high` [S]
The Mac sends these as terminal. The phone logs and falls back into its ordinary reconnect loop, so a
revoked device dials forever, showing "Reconnecting" with no explanation and no path to re-pair.

**B-14 · Mac measures pairing/QR expiry on the wall clock** — `medium` [S]
`protocol.md` requires monotonic and Android uses `elapsedRealtime()`. An NTP step during a pairing
window expires the attempt early or extends it. Needs a monotonic reading on `EkoClock`.

**B-15 · The phone accepts `ack{seq:0}`** — `medium` [S] — which the shared malformed vector requires
it to reject. Invisible because the ack vectors only run against the side that never receives acks.

**B-16 · `unpair_ack` is unreachable in every state on the phone** — `low` [S]
`SessionInboundValidator.kt:82,98` — listed as legal in `RESTRICTED_UNPAIR`, then rejected two lines
later by the catch-all type gate. Latent; a trap the moment either side sends it.

<a id="b-17"></a>
**B-17 · `ext_types` can never be negotiated** — `low` [S] — the Mac advertises it, the phone does
not, and `welcome.caps` is the intersection. So the protocol's only forward-compatibility escape
hatch is dead, and its `ignore` vector is unreachable. **Adding one string to
`WireJson.capabilities` unblocks several items in §5.**

**B-18 · `error.code` enum enforced only by the Mac** — `low` [S] — the phone accepts any string.

**B-19 · The phone closes the pairing socket after `welcome`** — `low` [S] — `protocol.md:338` says
the connection continues into normal sync, and the Mac waits 90 s for `backlog_start`. Every first
post-pairing sync costs a wasted Mac-side session and a full reconnect.

**B-20 · Different `device_name` in pair vs. normal hello** — `low` [S] — the user confirms
"Pixel 8" in the pairing sheet and then watches the chip rename itself to "Google Pixel 8". One
shared `localDeviceName()`.

---

## 2. Performance

<a id="p-01"></a>
**P-01 · The feed query cannot use an index, and every event dirties the `device` table** — `high` [S]
`EkoStore.swift:214,801,1701,1793`

Four compounding problems, of which #22 fixed only the last:

- Every committed event runs `UPDATE device SET processed_through_seq, last_seen_ms`, and both live
  `ValueObservation`s read `device` — so GRDB's tracked region is invalidated by every ingest,
  including `removed` and `capture_gap`.
- `ORDER BY n.received_at_ms DESC` has only `notification_received_idx (device_id, received_at_ms)`
  available, unusable for a global ordering when no `device_id` predicate is present — the default
  panel state. `notification` is `WITHOUT ROWID`, so this is a full scan plus a temp b-tree sort with
  `LIMIT` applied after. Search adds a leading-wildcard `LIKE`.
- Each surviving row pays a correlated subquery for its latest OTP.
- `observeAppPreferences` runs an unconditional full scan + `GROUP BY` on the same trigger.

*Fix:* `CREATE INDEX notification_recent_idx ON notification(received_at_ms DESC)`; move
`last_seen_ms` out of the per-event write (session start/end plus a coarse timer); throttle
observation delivery ~150 ms; consider a denormalized `latest_otp_id` maintained at ingest.

<a id="p-02"></a>
**P-02 · Extraction runs on the listener's main thread with uncached label lookups** — `high` [S]
`NotificationExtractor.kt:95`, `EkoNotificationListener.kt:65,118`
Two `PackageManager` binder round-trips per notification with no cache, plus a MessagingStyle Bundle
walk and a sanitizer that allocates a byte array per length measurement over a 64 KiB `bigText`. The
amplified case is reconciliation, which runs the whole pipeline over *every* active notification in
one main-thread pass — 80–120 binder calls in a frame on a busy phone. And it is user-triggered:
`updateRule` calls `reconcileActive()`, so flipping a toggle in the Apps list stalls the UI thread.
Needs an `LruCache` invalidated on `ACTION_PACKAGE_*`, and the mapping loop off the callback thread.

**P-03 · Backlog replay materializes the entire outbox twice** — `high` [S]
`EventRepository.kt:203`, `WireJson.kt:66`
`backlog()` loads the whole replay window (up to 2 000 rows with full `payload_json`) inside one
transaction; `WireJson.backlog` then eagerly decodes and re-encodes all of them into `JsonObject`
trees held simultaneously, typically 5–10× the source strings. Peak heap is tens of MB on a device
with a 128–192 MB budget. And because the read is one Room transaction, **the capture writer is
blocked behind it** — live notifications are not committed until the snapshot closes.
`boundedActiveChunks` compounds it by re-serializing the whole chunk to measure it, O(n²) in bytes
over up to 4 096 entries. Page it with the existing `eventsAfter(afterSeq, limit)`.

**P-04 · Every feed row observes the whole `AppModel` and builds its own formatter** — `high` [S]
`PanelViews.swift:292,396`
`NotificationRow` takes `@ObservedObject var model: AppModel`, so every visible row is invalidated by
*any* published change — for four callbacks and `model.now`. And `relativeDate` constructs a new
`RelativeDateTimeFormatter` per row per body evaluation, which is the classic per-frame formatter
allocation. Pass closures plus `now` as a value and make the row `Equatable`; hoist the formatter.

**P-05 · `AsyncThrowingStream`'s unbounded outer buffer defeats `bufferingNewest(1)`** — `medium` [S]
`EkoStore.swift:1146,1166,1217` — all three observation wrappers coalesce GRDB correctly and then
yield into a stream constructed *without* a buffering policy, which defaults to `.unbounded`. The
MainActor consumers then walk every stale snapshot in order. **One word, three times.**

**P-06 · Inbound queue is unbounded with an O(n) dequeue** — `medium` [S] · `NetworkTransport.swift:162,191`
`receiveNext()` re-arms unconditionally, so TCP flow control never engages and peak memory tracks the
whole backlog. `messages.removeFirst()` on an `Array` is O(n), making a full drain O(n²). Same defect
as [S-01](#s-01), which is its security-facing half — fix once.

**P-07 · OTP extraction allocates one `String` per Unicode scalar** — `medium` [S]
`OTPExtractor.swift:81,193` — `normalizeDigits` heap-allocates per scalar over the **full** text; the
1 000-character cap is applied only *after* it and two other full-text passes. Wire limits permit
512 KB, so one fat notification drives ~500k transient allocations, on the session actor's executor,
directly delaying the next commit and ACK. Cap first; short-circuit when no scalar is Arabic-Indic.

**P-08 · Retention and pruning re-scan the whole outbox on the write path** — `medium` [S]
`EventRepository.kt:258,266,300`, `Daos.kt:42`
`applyRetention` materializes every pending row *including payloads* to compute two integers, once per
pairing every 32 commits. `prunePhysicalRows()` is an unbounded full-table-scan DELETE with a
correlated subquery, run on **every ACK** — ~100 ACKs × 2 000 rows per replay. `pairingQueueDepth`
counts by materializing rows. All three want projection queries; the prune wants an index-range
delete bounded by `minRetainedSeq`.

<a id="p-09"></a>
**P-09 · `BootAwareClock.now()` fsyncs SharedPreferences per event, inside the write transaction**
— `medium` [S] · `BootAwareClock.kt:17`
Wall time always advances, so the guard is always true and every `now()` does a synchronous XML
rewrite. It is called at least twice per notification, both inside `withTransaction` on a
`synchronous=FULL` database — tripling the durable-write cost and lengthening exactly the window that
makes the 256-slot writer queue overflow. Keep the watermark in memory, persist lazily.

**P-10 · Launch does migration, Keychain and a synchronous read on the main thread** — `medium` [S]
`AppDelegate.swift:53,102`, `StatusPanelController.swift:29`
`AppRuntime()` is constructed synchronously on main: pool open, `PRAGMA synchronous = FULL`
verification, seven migrations, Keychain I/O and — on first launch — **P-256 key generation and a
certificate mint**. Then `StatusPanelController.init` eagerly builds *both* hosting views, including a
720×560 Settings window the user may never open, whose SwiftUI tree then subscribes to `AppModel` for
the process lifetime. This app is designed to launch at login.

**P-11 · QR image regenerated by `CIFilter` on every body evaluation** — `medium` [S]
`PanelViews.swift:534` — no `@State`, no memoization, and `PairingView` observes `AppModel`, which
publishes continuously during pairing. The payload is fixed for the invitation's lifetime.

**P-12 · Group-by-device is O(devices × notifications) per body evaluation** — `low` [S]
`PanelViews.swift:227` — two full scans of the 400-element array per device, producing new array
instances each pass and defeating SwiftUI's identity diffing.

---

## 3. Interface — macOS

**M-01 · Gap rows print raw wire enum tokens** — `high` [S] · `PanelViews.swift:414`, `SettingsView.swift:241`
The most user-facing warning in the product reads *"Telefon könnte Benachrichtigungen verpasst haben ·
writer_overflow"* — an untranslated snake_case protocol token, in an app whose selling point includes
complete EN+DE localization. Settings → Diagnostics has the same leak via `String(describing:)` on
three state enums, truncated to two lines. `GapSpan.startTime`/`endTime` are decoded and never
rendered; "may have missed notifications" without a time range is not actionable.

**M-02 · The error strip is permanent** — `high` [S] · `AppModel.swift:107,190`, `PanelViews.swift:134`
`fatalError` is written in exactly one place and never cleared; `ErrorStrip` has no dismiss, no retry,
no expiry. And it is set from *transient* conditions — a failed `setStarred`, a failed export,
`beginPairing` before the listener has bound. So clicking Add phone one second too early after launch
pins a full-bleed red bar across the panel for the rest of the process lifetime. The bar is also
`Color.red.opacity(0.88)` with white `.caption` text, ~3.5:1 and backdrop-dependent.

**M-03 · Definitive gap rows are undeletable and permanently pinned** — `high` [S]
`PanelViews.swift:159`, `EkoStore.swift:1568`
`prune` deliberately never deletes definitive gaps in the current generation, because cursor coverage
depends on them. That is correct for the protocol. The UI consequence is a warning banner that is
*literally permanent*: after one retention overflow, an orange "History unavailable" row sits above
every notification forever. Three of them consume ~120 pt of a 620 pt panel. Separate storage
durability from display — an acknowledged flag and a collapsed "N history gaps [Show]" chip.

**M-04 · Row actions are hover-gated and resize the row** — `high` [S] · `PanelViews.swift:349,385`
For every non-OTP notification the actions exist only while a pointer is inside the row. No
`@FocusState`, no `.focusable()`, no `contextMenu` anywhere in `macos/App/`, and the feed is a
`LazyVStack` rather than a `List`, so rows are not focusable or selectable — **a VoiceOver or
keyboard-only user cannot reach any per-notification action at all**. The ~20 pt bar also lives inside
the row's `VStack`, so hovering grows the row and shoves everything below it down, with no animation;
rows sliding under a stationary pointer then cascade into hover flicker while scrolling. And
`.accessibilityElement(children: .contain)` with `.accessibilityLabel` is contradictory — VoiceOver
reads the summary and then re-reads every child.

**M-05 · Unpair fires immediately; the less destructive Forget is confirmed** — `high` [S]
`SettingsView.swift:123` — the app guards the recoverable action and leaves the irreversible one one
click away, as two identical small destructive buttons in the same row. Recovery is the full pairing
flow on the phone.

**M-06 · `PreferenceRow` copies its model into `@State` at init** — `high` [S] · `SettingsView.swift:191`
`State(initialValue:)` is honoured only on first construction, and the parent list is driven by a live
`observeAppPreferences()` stream. Any change not originating from this row — including its own
round-trip echo — is silently discarded, while `onChange` writes on every mutation. **A write-only
surface whose displayed state can permanently diverge from what is persisted.**

**M-07 · Pairing has no manual fallback** — `high` [S] · `AppModel.swift:214`, `PanelViews.swift:475`
`PairingDisplay` carries the one-time `token` and the view never renders it. PLAN specifies QR *plus*
a manual line precisely so pairing survives a broken camera or a phone that cannot scan; as shipped
there is no fallback path at all. The fingerprint is also truncated and not selectable, so it cannot
be copied to compare.

<a id="m-08"></a>
**M-08 · Banner authorization is provisional-only and nothing surfaces it** — `high` [S]
`NotificationCoordinator.swift:43,105`
Provisional authorization means **quiet** delivery — no banner — until the user promotes the app. Since
native banners with a Copy code action are the headline feature, the default first-run experience is
that nothing visibly happens when a code arrives. `UNAuthorizationStatus` is never read, and there is
no `willPresent`, so even after promotion banners are suppressed while Eko is frontmost — which is
exactly the state `showPanel()` forces.

**M-09 · Contrast failures in light mode** — `medium` [S] · `PanelViews.swift:264,286,409`
`FilterButton` pairs literal white with `Color.accentColor`, which on macOS resolves to the *user's*
System Settings accent unless it is Multicolor — white-on-yellow is ~1.2:1, completely illegible. The
degraded-network strip is system orange on an orange tint at ~1.7:1, and it is the message that
explains why discovery silently stopped working. The suspected-gap icon is ~1.3:1.

**M-10 · Header layout: fixed height, greedy ScrollView, no overflow affordance** — `medium` [S]
`PanelViews.swift:46,84,195` — two flexible children split the residual width by proportional rules, so
the device-chip strip clips at a boundary unrelated to how many devices exist, with indicators
disabled and no edge fade. The 48 pt and 30 pt hard clamps crop rather than expand under the macOS
Accessibility text-size setting.

**M-11 · Connection state is an 8 pt monochrome glyph difference** — `medium` [S] · `PanelViews.swift:98`
Below the legibility floor, with no colour at any state and no hover or pressed feedback. The panel's
primary at-a-glance readout is available only via tooltip.

**M-12 · Settings rows overflow the minimum window width** — `medium` [S] · `SettingsView.swift:94,200`
The Devices row puts an unbounded 64-hex fingerprint (~380 pt), a name, a 27-character German state
label and two buttons in one non-wrapping HStack inside ~604 pt. `PreferenceRow` constrains the
delivery `Picker` to 120 pt, which must hold both its label and a popup whose widest German option is
"Ausgeblendet".

**M-13 · Empty state shows the wrong message when a filter returns nothing** — `medium` [S]
`PanelViews.swift:163` — typing a query with no matches says "New notifications from your phones appear
here", which is false and offers no way out of the filter that produced it. Also top-anchored under a
magic `.padding(.top, 56)` instead of centred.

<a id="m-14"></a>
**M-14 · Star / Keep has no visible effect anywhere** — `medium` [S] · `PanelViews.swift:359`
`isStarred` is consumed nowhere but the button's own label, there is no way to *list* starred items,
and the only real consequence — `prune` exempts them — is invisible. Users are invited to curate a
collection they can never look at.

**M-15 · Copy actions give no feedback at all** — `medium` [S] · `AppModel.swift:250`
No checkmark, no label swap, no sound, no VoiceOver announcement. The product's central interaction
produces zero perceptible response, and the clipboard then silently empties 120 s later.

**M-16 · Pairing title mis-centred; QR resampled at a non-integer ratio** — `low` [S]
`PanelViews.swift:448,531` — a hardcoded 44 pt counterweight against a ~52 pt (EN) / ~62 pt (DE) Back
button, and a 10× filter output down-scaled into 220 pt with nearest-neighbour, which drops whole
module rows on the one screen that must scan reliably.

**M-17 · Diagnostics log: duplicate identities, no wrap, no live tail** — `low` [S] · `SettingsView.swift:249`
Keyed on `timestamp`, which the recorder can emit in bursts; long messages clip horizontally with no
wrap; refreshes only on appear or an explicit click, so a user reproducing a problem watches a frozen
log.

**M-18 · No About window, no version display, no Help, no update path** — `low` [S]
`CFBundleShortVersionString` is read exactly once, to stamp the diagnostics export. A user cannot find
which build they are running. With Developer-ID/sideload distribution there is also no mechanism at
all to deliver a fix to an installed copy.

---

## 4. Interface — Android

**A-01 · Permission denials produce silently dead buttons** — `high` [S] · `MainActivity.kt:72,135`
Camera denial does nothing at all — no message, no rationale, no route to Settings — and after the
second denial the system dialog stops appearing, so "Scan QR code" becomes a button that visibly does
nothing, forever. POST_NOTIFICATIONS is the same shape. Neither path calls
`shouldShowRequestPermissionRationale`, and there is **no `Snackbar`/`SnackbarHost` anywhere in the
module**, so there is no channel for transient feedback at all. Returning from Settings without
granting leaves the card byte-identical.

**A-02 · Checklist state is conveyed by colour and a null-described icon** — `high` [S]
`EkoScreens.kt:257,266,439`
`status` is optional and several cards omit it, so for a TalkBack user the pairing card reads
identically whether or not pairing succeeded — **no way to hear which steps are complete.** Also a
plain WCAG 1.4.1 failure. The affordances contradict the state too: notification-access and CDM cards
keep offering their action when already satisfied, so a finished checklist still looks unfinished.
There is no progress indicator of any kind in the app.

<a id="a-03"></a>
**A-03 · Force-stop silently pauses forwarding with no explanation** — `medium` [S]
`EkoApplication.kt:60,76` — the product is off, the only clearing path is the Home master switch,
`SystemChecks` does not carry `forwardingPaused` at all, and every checklist card still reads green.
The behaviour is defensible; the silence is not. See also [B-08](#b-08), which makes it fire far more
often than intended.

**A-04 · Diagnostics leaks raw internals** — `medium` [S] · `EkoScreens.kt:631`, `TransportRuntime.kt:43`
Untranslated Kotlin class names where localized `status_*` strings already exist; raw epoch millis,
because `log()` prefixes every line with `System.currentTimeMillis()`; a numeric `ApplicationExitInfo`
constant rendered as "Recent process exit reason: 10"; raw presence events and association IDs. All
100 log lines render eagerly inside one `LazyColumn` item. Meanwhile `lastTransition`,
`commitFailures` and `reconciliationFailures` are collected and never shown, though PLAN lists NLS
bind transitions as a requirement.

**A-05 · Foreground-service notification has no deep link** — `medium` [S] · `ConnectionService.kt:214`
A bare launch intent with no extras, and `MainActivity` has no `onNewIntent`. The notification saying
"Reconnecting to paired Macs" lands on Setup rather than Home or Diagnostics. It is also state-blind
about *which* Mac.

**A-06 · The Apps screen is the raw-toggle wall the product is trying not to be** — `medium` [S]
`EkoScreens.kt:559`
100–200 cards and 300–600 switches in one flat list, with no search, no filter, **no app icons**
(trivially available from `PackageManager`, and the single highest-impact visual upgrade here), no
grouping, no use of the `lastSeenWall` already in the row, no explanation of what "Contains codes"
does, and no bulk actions. Both Apps and Home also flash their empty state before real data loads,
because `stateIn` starts at `emptyList()` — an empty state shown to users who are not empty.

**A-07 · Pending pairings and the `+` action are ambiguous** — `low` [S] · `EkoScreens.kt:129,340`
Pending pairings are unlabelled bare `TextButton`s with no expiry, no endpoint and **no way to dismiss
one** — cleared only by `HealthWorker`'s 15-minute prune. The top-bar `+` merely switches to the Setup
tab, duplicating the tab two inches below it. And the SAS verify dialog is owned by `OnboardingScreen`
rather than hoisted to the root, so changing tabs mid-verification makes the security-critical code
disappear while the handle keeps ticking toward expiry.

---

## 5. Security & privacy

<a id="s-01"></a>
**S-01 · Unbounded inbound frame queue, reachable pre-confirmation** — `high` [S]
`NetworkTransport.swift:132,162,174`
`receiveNext()` always re-arms and appends into an uncapped array. The consumer has long stalls —
most importantly `runPairing` blocking on `await pairingApproval(pending)` for up to the 5-minute
attempt expiry while the user decides. Nothing is read during that window and the reader keeps
enqueuing. **That window is reachable by any peer pairing mode admitted, before any user
confirmation**, so a LAN host can grow the Mac's memory until it is OOM-killed. Cap count *and* bytes,
and either apply real backpressure or treat overflow as a protocol violation.

**S-02 · Pairing admission latches the fingerprint inside the TLS verify block** — `medium` [S]
`TLSListener.swift:129`, `PeerAdmission.swift:58`
`admitUnknown` is not a pure predicate — it mutates `admittedFingerprint` during the handshake. So the
**first LAN host to present any self-signed leaf claims the single TOFU slot**, before any QR scan, any
SAS, any user action, and the legitimate phone cannot pair until the window is restarted. A
denial-of-pairing rather than a trust bypass, but trivially triggerable by anything on the network.

<a id="s-03"></a>
**S-03 · macOS diagnostics export ignores the documented redaction contract** — `high` [S]
`DiagnosticsRecorder.swift:72`, `docs/diagnostics.md:57`
The docs define a mandatory redaction table and state that a default export "must transform sensitive
values before writing the archive, not merely hide them in the UI". The exporter honours exactly one
row (title/body dropped). Device IDs, device names, certificate fingerprints and addresses are written
verbatim — and the support docs route every escalation through this file.

**S-04 · Banking/TAN exclusion inspects only the body** — `medium` [S] · `NotificationCoordinator.swift:110`
PLAN promises auto-copy is "never for banking/TAN messages"; the gate is one regex over `outcome.body`,
which never includes the **title** and never considers the **app identity**. A message titled "Zahlung
freigeben" with body "Code: 481920" passes. (The regex is also recompiled per call.)

**S-05 · Bonjour advertises a permanent identity fingerprint on every network, always** — `medium` [S]
`BonjourPublisher.swift:31` — the TXT record carries the Mac's 64-hex certificate fingerprint, from a
cert minted with 20-year validity that never rotates, under the service name "Eko on ⟨computer name⟩",
unconditionally and re-armed on every network change, with no off switch. Join a café network and Eko
broadcasts a stable, globally unique tracking identifier plus your computer's name to the segment.
Publish `fp` only during pairing; add an "Advertise on the local network" toggle.

**S-06 · Copied OTP codes go to `NSPasteboard.general`** — `medium` [S] · `ClipboardController.swift:14`
`org.nspasteboard.ConcealedType` is a community convention honoured by cooperating clipboard managers;
it is not an Apple mechanism and does not mark the item local-only. The general pasteboard is the one
Universal Clipboard replicates to every device on the same iCloud account. For a product whose premise
is keeping OTPs on your own paired devices, this deserves an explicit decision and an explicit sentence
in the docs.

**S-07 · `UdpHintListener` accumulates attacker-controlled entries without bound or expiry** — `low` [S]
`UdpHintListener.kt:55` — rate limits apply per source host, but the published list has neither cap nor
expiry and dedups on an attacker-chosen `fingerprint`. One host emitting a packet every 500 ms with a
fresh random fingerprint fills the pairing UI with spoofed "Macs", each with an attacker-chosen name.
Also: mark mDNS/UDP-sourced chips as *unverified*, since only the QR path carries an authenticated
fingerprint.

---

## 6. Missing features

<a id="f-01"></a>
**F-01 · Promised in PLAN or docs, not implemented** — `high`

| Promise | Where |
| --- | --- |
| Global keyboard shortcut for panel / latest code (⌃⇧⌘V, opt-in, collision warning) | PLAN:1218 |
| Per-device banner pause + macOS Focus auto-pause — the `allowsBanner(deviceID:)` seam exists and its only implementation ignores the parameter | PLAN:1198 |
| Android onboarding step 9: send a test notification, round-trip proof | PLAN:1256 |
| Per-device retention in the Devices pane — global-only on the Mac; the phone's per-pairing columns exist with no caller | PLAN:1213 |
| Inline backlog banner — surfaced as a system notification instead, a banner about banners | PLAN:1179 |
| "Mute this app" as a row action — store side fully implemented, reachable only via Settings | PLAN:1193 |
| "Identity changed — re-pair required" flow — neither side implements it; the Mac just fails the handshake silently | install-and-pair.md:130 |
| Android diagnostics export — does not exist; the transport log is in-memory only and dies with the process | diagnostics.md:13 |
| Delete-history control — no such control; bulk deletion is private and reachable only via unpair | privacy-and-data-handling.md:93 |
| Update notice — neither app can tell the user a new version exists | PLAN:467 |
| macOS notification-authorization upgrade prompt | PLAN:614 (see [M-08](#m-08)) |

**F-02 · The Mac cannot say "notification access is off on the phone"** — `high` [S]
PLAN:1206 lists this as a first-class degraded state. The wire protocol carries **no phone-health
signal at all** — `hello` has no listener-bind state, no access grant, no redaction self-check, no
forwarding-paused. `ConnectionService` connects and heartbeats regardless of whether the listener is
bound, so a phone whose notification access was revoked — a routine consequence of an Android update
or restricted settings — shows as **a green, connected chip that silently delivers nothing.** That is
the worst possible failure mode for this product: it looks like it is working. Needs an optional
`health` object on `hello`/`ping`, must-ignore on older peers — which needs [B-17](#b-17) first.

**F-03 · Starring is fully plumbed with no way to view starred items** — `medium` — `FeedQuery` needs
`starredOnly`, `fetchNotifications` a predicate, the filter row a third chip. See [M-14](#m-14).

<a id="f-04"></a>
**F-04 · History is 400 rows deep, and muting an app erases it from history** — `medium` [S]
`AppModel.swift:410`, `EkoStore.swift:1717` — one fixed `limit: 400` query with no pagination, no
"show older" and no date jump, while retention defaults to 7 days / 5 000 and goes to 90 days / 50 000.
90 % of the history the user is paying disk for is unreachable except by search, and the retention
steppers imply the opposite. Separately the feed filters `banner_mode != 'muted'`, so muting an app for
*banners* also erases it from *history* — which is not what "mute" means anywhere else.

<a id="f-05"></a>
**F-05 · Auto-pause after a Task-Manager stop is silent** — `high` [S]
PLAN:1288 specifies "persist paused forwarding, **explain status**, and require explicit in-app
Resume". The persist half is implemented; the explain half does not exist. Pairs with [A-03](#a-03)
and [B-08](#b-08).

**F-06 · Per-app rules only exist for apps that already notified** — `medium` [S] — both sides derive
the list from traffic, so there is no way to pre-mute a noisy app and no curated defaults, though PLAN
promises "default: all except ongoing/media" as a policy.

**F-07 · Phones are indistinguishable and unrenameable** — `medium` [S] — the name comes from the
build, neither side offers a rename, and the Mac overwrites it from `hello` on every connection. For
the product's stated multi-phone premise, two of the same model give two identical chips.

**F-08 · What a switcher reaches for first** — `low` — inline reply, app icons in the feed, and shared
clipboard / send-file / ring-my-phone. All deliberately deferred, which is right; making the deferral
*visible* costs nothing. App icons are the cheapest large perceived-quality win and worth pulling into
the first point release.

---

## 7. Build, tests, docs

**C-01 · The Android transport session layer and the mTLS/pairing client have zero tests** — `high` [S]
`NormalPeerSession`, `TlsConnector`, `LanPairingClient`, `ConnectionService`, `TransportRuntime`,
`EligibleNetworkMonitor`, `AppliedReceiptSession` and `Receivers` are referenced by no test on either
the JVM or instrumented side. Starkly asymmetric with the Mac, where `SessionManagerTests.swift` is
38 KB over the same handshake/backlog/supersession logic — **and it is exactly where [B-10](#b-10),
[B-13](#b-13) and #17's reconnect fix live.** Two seams make most of it testable without a device:
drive `NormalPeerSession` over an in-memory frame pipe fed by `protocol/test-vectors/scenarios/*.json`,
and test `TlsConnector`'s pinning against a local `SSLServerSocket` with a known-good and known-bad leaf.

**C-02 · Seven of eleven scenario vectors are consumed by no test; Android consumes none** — `medium` [S]
macOS consumes `pairing-retry`, `resume`, `supersession`, `unpair`. Android consumes zero scenarios.
Unconsumed: `active-chunks`, `generation-transition`, `invalid-ack`, `multi-mac-retention`,
`peer-cursor-regression`, `retention-gap`, `stale-fetch` — precisely the durability edge cases the
design exists to get right. Four map directly onto logic already hand-tested in `EventRepositoryTest`
and `EkoStoreTests`; swapping those fixtures for the shared vectors is nearly free and turns them into
real conformance tests. (`scripts/check-protocol.py` validates them as *data*; nothing executes them.)

**C-03 · `:core`'s JDK-17 toolchain breaks the build on any other JDK** — `medium` **[V]**
`:core` alone declares `kotlin { jvmToolchain(17) }`; the other five use `compileOptions` and compile
on whatever JDK Gradle runs, and `settings.gradle.kts` configures no toolchain resolver. Reproduced
here on JDK 21:

```
> Could not resolve project :core.
   > Cannot find a Java installation on your machine matching: {languageVersion=17, …}.
     Toolchain download repositories have not been configured.
```

CI is unaffected (`setup-java` pins 17), so this is a local-development footgun. Pick one policy —
drop the toolchain, or add the foojay resolver and apply it uniformly.

**C-04 · Two of CICD.md's planned jobs cannot run on their assigned runner** — `medium` [S]
The `otp-corpus` job is assigned `ubuntu-latest`, but the corpus is executed only by
`OTPCorpusTests.swift`, which does `@testable import EkoCore` and link-depends on
AppKit/Security/CoreBluetooth — and per locked decision D7 there is no Kotlin extractor to run it
against. `macos/README.md` says explicitly the package will not build on Linux.

**C-05 · Documentation contradicts the code** — `medium` [S]
`docs/diagnostics.md` documents an Android export that does not exist; the macOS export is a single
JSON file, not the ZIP the docs tell users to unzip; two user docs instruct a synthetic test
notification and a panel keyboard shortcut that were never built; `macos/README.md`'s build command
omits the destination and code-signing flags the sanctioned gate requires; the release checklist's
entitlement allowlist omits a shipped, required entitlement.

**C-06 · Supply chain and tooling** — `medium` **[V]**
No `Package.resolved` is committed and `swift-crypto` is pinned as a range, so macOS builds are not
reproducible. No version catalog: `androidx.core:core-ktx` and `kotlinx-coroutines` versions are
duplicated verbatim across four and five module files. `:outbox` uses `kapt` for Room, which lint
flags — with Kotlin 2.2, kapt is legacy and KSP is materially faster. And **no test on either platform
asserts that a redacted diagnostics export contains no notification content** — the one property the
redaction contract exists to guarantee (see [S-03](#s-03)).

**C-07 · Remaining lint findings** — `low` **[V]** — six `ApplySharedPref` synchronous `commit()` sites
(one of which is [P-09](#p-09)), one `PluralsCandidate` in the app module, four unused string
resources, `TypographyEllipsis`, and a `DiscouragedApi` on `getIdentifier` (the *label* half of
[P-02](#p-02); the redaction-marker half is fixed in #18).

---

## 8. Aesthetic direction

The individual defects are in §3 and §4. This is the shape of the answer to *"make it look like a
high-value app rather than a mid one"*.

The honest diagnosis: **nothing here was designed; it was assembled.** Every surface is a direct,
literal rendering of a state machine — a card per permission, a row per notification, a
`String(describing:)` per enum. There is no visual hierarchy beyond "things are in a list", no motion,
no brand voice, and no shared vocabulary of radius, spacing, type or colour. That is what reads as
"mid", on both platforms, and it is a bigger gap than any individual bug in this document.

<a id="d-01"></a>
**D-01 · Build a design-token layer first** — `idea`, medium effort. Everything else here depends on it.

`PanelViews.swift` alone uses **seven independently chosen corner radii** — 8, 9, 10, 11, 12, 18, plus
Capsules — and every one is `.circular` where Apple's own surfaces are `.continuous`. Circular corners
beside the system's continuous corners on the same screen is one of the most reliable tells that a Mac
app was not designed on the platform. Padding is equally ad-hoc: 4, 5, 6, 7, 8, 9, 10, 11, 12, 18, 56
as bare literals. The type ramp mixes semantic styles with five absolute sizes, and `design: .rounded`
appears exactly once — on the wordmark — so the brand voice exists in one place and nowhere else.
Colours are `Color.primary.opacity(0.05/0.06/0.07)` for what is conceptually one "subtle fill", plus
bare `.white`, `.red`, `.orange`, `.yellow`.

A small `DesignSystem.swift`: `Radius` (sm/md/lg, all `.continuous`), `Spacing` on a 4 pt grid,
`Typography` (named roles, `.rounded` applied consistently to numerals and codes), `Palette` (surface,
surfaceRaised, hairline, accentText, warning, danger — defined for light *and* dark, reactive to
`colorSchemeContrast`). Then mechanically replace every literal. A day of work that raises perceived
quality more than any single feature.

The Android mirror: generate a full tonal palette from the seed so every `on*` role is deliberate —
today `onSecondary`, `onBackground`, `onSurfaceVariant`, `outline` and `errorContainer` are left at M3
baseline, which are **purple-tinted neutrals sitting under a green-tinted surface set**. Replace the
`containerColor = …copy(alpha = 0.55f)` calls, since an alpha copy means `contentColorFor` cannot match
the role and content silently falls back to `onSurface`.

<a id="d-02"></a>
**D-02 · Finish unifying the brand** — `idea`, small effort. #20 aligned the Android launcher icon to
the macOS `BrandMark` and added the monochrome layer. What remains: the palettes still disagree —
Android seeds from `#075E54` (which is, notably, WhatsApp's green) while the macOS mark is a
`#22C6B7 → #13759F` gradient and the AccentColor asset is teal. Pick one and derive both platforms'
assets from it.

<a id="d-03"></a>
**D-03 · Design a real OTP card** — `idea`, medium effort. The OTP treatment today is the same rounded
rectangle as every other row, tinted `accentColor.opacity(0.1)`. Extracting the code is **the reason
the product exists** and it is rendered as a 10 %-opacity variation on a generic list row. Give it a
distinct card: a raised material or accent gradient, the code as grouped monospaced digit tiles
(`448 291`) at ~32 pt with tabular figures, the source app as a quiet caption, one large affordance the
whole card responds to, a thin auto-clear countdown ring, a subtle scale on first appearance. **That
one card is what the screenshot on the sales page should be.**

Grouping is safe because it is purely presentational — the extractor already strips separators, so the
stored form is canonical. Format 6 as 3+3 and 8 as 4+4, leave alphanumeric codes alone, keep
`.textSelection` on the unformatted value, and set an accessibility label that spells the digits so
VoiceOver does not read "448,291" as a number.

**D-04 · Add motion — and the accessibility switches that turn it off** — `idea`, medium effort.
Grepping `macos/App/` for `withAnimation`, `.animation(`, `.transition(` returns **one hit**. Grepping
the Android app module for `AnimatedVisibility`, `Crossfade`, `animate*AsState`, `AnimatedContent`
returns **zero**. Notifications pop into the list, the route swap replaces the content instantly, gap
rows appear abruptly, hovering snaps a row's height. It feels less like a native app than like a web
page re-rendering.

Correspondingly, `macos/App/` contains **zero** `@Environment(\.` reads — the app never consults
`accessibilityReduceMotion`, `accessibilityReduceTransparency`, `colorSchemeContrast` or
`dynamicTypeSize`, so there is nothing to disable and nothing to strengthen when a user turns those on.
(`.ultraThinMaterial` handles Reduce Transparency itself; the hand-rolled `Color…opacity()` surfaces do
not.) Ship the motion and the switches together.

**D-05 · Make the panel keyboard-first** — `idea`, medium effort. `showPanel()` sets no first responder
and there is no `@FocusState` in the app, so opening the panel and typing does nothing. Return does
nothing; the feed is a `LazyVStack`, so there is no selection model, no arrow navigation, no focus ring.
For a menubar app whose whole value is speed, the interaction is mouse-only end to end. Focus search on
open; ↑/↓ to move; Return to copy; ⌘⌫ to dismiss on the phone; `/` to search; ⌘1…⌘9 to grab the Nth
code. (#21 added the Edit menu and Escape, which is the precondition.)

**D-06 · Replace the Android checklist wall with a staged pager** — `idea`, large effort.
`OnboardingScreen` presents all eight cards at once — ~400 words of system-permission prose and six
buttons before the user does anything. The restricted-settings card is shown to *every* Android 13+
user who has not yet granted access, **before** the notification-access step, so the first thing a new
user reads is a warning about a failure that has not happened yet. A `HorizontalPager` with one step per
page, a progress rail, one illustration, one sentence, one button; only applicable steps;
restricted-settings surfaced *reactively*. End on the missing step 9 — send a test notification, watch
it round-trip, animate a checkmark — which turns a permissions gauntlet into a moment of confidence.

---

## 9. Ideas

Ranked by delight × feasibility. ⚡ are the cheap ones.

**⚡ I-01 · Make copying a code a moment** — trivial. Morph the button to a checkmark with
`.contentTransition(.symbolEffect(.replace))`, draw a 120 s ring that drains — driven by the same
`EkoClock` the controller uses, so it cannot lie — and fade it when the wipe fires. Optional short
click, off by default, never during replay. Gate on Reduce Motion; announce for VoiceOver. Today the
central interaction produces zero response and the clipboard silently empties two minutes later, which
reads as a bug.

**⚡ I-02 · "Open link on Mac" row action** — trivial, and the cheapest genuinely useful feature here.
Bodies arrive complete and stored verbatim, and the OTP extractor already carries a well-tested URL
regex which it uses to *delete* URLs. Promote it to a shared `LinkExtractor`, render "Open ⟨host⟩" in
the action strip, `NSWorkspace.shared.open`. Show the resolved host, never the display text, so a
phishing notification cannot disguise its destination. Never auto-open. "A link arrived on my phone, I
want it on my Mac" is a top-three reason people install a mirroring tool; today the answer is "retype it".

**⚡ I-03 · Per-phone colour identity from the deviceId hash** — trivial. `Device.id` is a SHA-256 hex
fingerprint, so a stable hue is free: first two bytes → one of ~12 well-separated hues, fixed
saturation and brightness for contrast in both appearances. Apply to the chip fill, a 3 pt leading edge
on the row, and the group header. In the two- or three-phone household the product explicitly targets,
the feed is currently a wall of identical rectangles. Keep the name on every surface.

**⚡ I-04 · Read-friendly OTP grouping** — trivial. Humans read `448 291` and transcribe `448291`; they
misread `448291`. Display layer only; see [D-03](#d-03).

**⚡ I-05 · Device chips should say when the phone was last seen** — trivial. PLAN sketches the tooltip
as "last seen + state"; shipped is state only, and `Device.lastSeen` already exists and is already
rendered in the Devices pane. "Disconnected" with no timestamp is the difference between "in the next
room" and "dead since Tuesday". Then a soft *away* distinction: within ~5 minutes reads as Away (hollow
ring), older as "Offline · 3 h ago".

**I-06 · A fourth banner mode: "Codes only"** — small. `BannerMode` is `normal | silent | muted`, and
the delivery guard already computes `(kind == .posted || otpBannerEligible)` on the very next line —
the machinery is literally already in the expression. Nobody ships this well: for a bank or an
authenticator you want the code and nothing else, and today the choice is everything or nothing. Seed
it from the phone's existing "contains OTPs" hint. **Careful:** `banner_mode != 'muted'` is also a
*feed* filter, so `codesOnly` must not filter the feed (see [F-04](#f-04)).

**I-07 · Sticky newest-code card with an honest age meter** — small. Pin the newest uncopied OTP above
the feed for ~3 minutes with a hairline meter, Copy as the default action. **Resist an expiry
countdown** — we cannot know the issuer's TTL, and a wrong countdown is worse than none. Label it as
*age* ("detected 40 s ago"), which is true, and dim the card once `copiedAt` is set.

**I-08 · Collapse conversation threads using `group_key`** — small. `group_key` is normative in the
schema, decoded into `NotificationContent.groupKey`, length-validated — **and never persisted**. So the
feed shows fourteen rows from one group chat. This is the "summarize a noisy app" payoff with no model
involved: Android already told us which notifications belong together. Forward migration, a "Collapse
threads" toggle, one row per `(device, app, group_key)` with an "Anna +13" expander. It also gives group
summaries a principled place to hide, which the extractor already skips.

**I-09 · "Dismiss all" — per app, per phone, or everything** — small. `dismiss` already exists and is a
negotiated capability; the feed already knows every active key. Clearing a phone's shade from the Mac at
the end of the day is genuinely satisfying and nobody does it well. Cap the batch, confirm above ~20,
pace the sends through the outbound actor.

**I-10 · Wire the per-device pause seam, plus Focus awareness** — small.
`allowsBanner(deviceID:)` takes a deviceID and the only implementation ignores it. The seam was designed
and then not used. `INFocusStatusCenter.default` + `focusStatus.isFocused` gives the boolean PLAN needs
(requires the Communication Notifications entitlement — make it opt-in, degrade silently). **Add a timed
variant** ("Pause for 1 hour"): a pause you can forget you enabled is a data-loss-shaped UX bug.

<a id="i-11"></a>
**I-11 · First-pairing celebration that doubles as the missing round-trip proof** — small. After
`PairingConfirmationView` resolves, `endPairing()` drops to `.feed` and the user stares at
`ContentUnavailableView` — **the emotional peak of the product lands on an empty state.** Build both
halves as one feature: Android gets the missing step 9 (a local notification through Eko's own package —
note `extract` currently returns null for `sbn.packageName == context.packageName`, so this needs a
deliberate allowlisted path); the Mac shows a one-time success state on the first event from a new
device. Once per device, dismissible, never again.

**I-12 · Global hotkey code-grabber** — medium. PLAN specifies it and nothing is built. Needs
`EkoStore.latestOTP(within:deviceID:)` (the `otp` table already has `detected_at_ms` and `copied_at_ms`).
Register with Carbon `RegisterEventHotKey` — it works **inside the App Sandbox with no Accessibility
grant**, unlike `NSEvent.addGlobalMonitorForEvents`. Flash a small HUD; if no fresh code, open the panel
focused on search rather than doing nothing.

**I-13 · A status item that conveys state** — medium. PLAN specifies a pulse on mirror, a badge dot plus
an opt-in code chip, a struck glyph with a *count*, and a progress arc during sync. Shipped is four
unrelated symbols that swap the icon's whole identity, so the mark a user learns to aim for changes shape
with connectivity. A small custom `NSView` with a stable glyph plus overlays; `BacklogSummary` already
flows through `AppSessionSink` for the arc. (#21 fixed the redraw storm and the never-expiring badge —
this is the design half.)

**I-14 · Backlog progress as a compact pill, and the missing inline banner** — medium. Completion is
announced as a system notification — a banner about banners — while during the replay the panel shows
nothing at all. Collapse the header into a pill while syncing (device colour dot, name, progress, count),
then `matchedGeometryEffect` it into the inline banner PLAN describes, with a [Show] that sets the
filters and scrolls to the first replayed row. Keep the system notification only for when the panel is
closed — the case it was actually right for.

**I-15 · Truncation shimmer** — small. `truncated_fields` is required and normative in every event, and
`body_complete` is a real column the feed filters on: the system takes "we may not have the whole text"
seriously all the way down. The UI expresses **none** of it — a body the phone truncated looks identical
to one SwiftUI merely clipped. Terminate such text with a short gradient shimmer instead of "…", with a
tooltip naming what happened. Tiny privacy theatre that is also literally true, which is the best kind.
Static hatched block under Reduce Motion.

**I-16 · Phone battery and signal glance** — medium. `ext_types` makes a new `phone_status` message
ignorable by construction on un-updated peers — the forward-compatibility work is already done, modulo
[B-17](#b-17). Keep it in memory only: it is not a notification and **must never consume a seq**. The
real cost is not the code — `protocol.md` is normative, so it needs a section, a schema and vectors.
Budget for that or it will rot.

**I-17 · "Ring my phone"** — medium. The Mac→phone control channel exists and is proven: `dismiss` goes
out via `session.transport.send` and lands on `NotificationListenerController.dismiss`. A `ring` message
is the same shape. **Security matters here:** only over a live confirmed session with a pinned cert,
never from a pending pairing, rate-limited hard, and the phone-side UI must always name which Mac asked
and offer "Stop and disable ringing". A compromised Mac that can make your phone scream at 3 am is a
genuinely bad outcome.

**I-18 · Android Home as a dashboard, not a socket readout** — medium. Home answers "is the socket up",
not "is my Mac getting my notifications right now". The data already exists and is unused:
`lastForwardWall` is rendered only in Diagnostics; `Connected` carries `sinceWall` and
`acknowledgedThrough` and both are discarded; `strings.xml` defines `last_ack` and it is **referenced
nowhere in the codebase.** Showing `host:port` and a fingerprint prefix as primary content while hiding
"last forwarded 4 seconds ago" is exactly backwards. Rebuild around evidence: a live dot, "Last mirrored
4 s ago", "Connected for 2 h 14 m", a sparkline, queue depth only when non-zero, and a per-Mac "Send test
notification" that doubles as [I-11](#i-11).

**I-19 · Shortcuts / App Intents plus a tiny CLI (`eko code`)** — large. Everything needed is already a
synchronous store read. This is what makes Eko a thing people build workflows around rather than an app
they open. **Treat it as a security surface:** any local process reading codes is a real risk — explicit
opt-in, every read logged to `DiagnosticsRecorder`, same auto-clear semantics as the panel.

**I-20 · Auto-paste into the frontmost app** — large, and be honest about it. The most delightful
possible behaviour, and it needs `CGEventPost` into another process, which needs an Accessibility grant,
which is **not obtainable in the App Sandbox** — and PLAN deliberately keeps the sandbox on so a Mac App
Store path stays open. Do not quietly drop the sandbox. Ship it as an opt-in capability in a Developer-ID
variant, behind `AXIsProcessTrustedWithOptions`, a per-app allowlist, and a hard rule that it fires only
within N seconds of the banner and only for `originBound` matches. Safe fallback everywhere else: copy
plus `NSRunningApplication.activate` so the user only presses ⌘V. Be prepared for the answer to be "no"
for MAS, and say so in Settings rather than shipping a toggle that silently does nothing.

**I-21 · Latest-code widget / Control Center control** — large, rank last. Blocked architecturally:
`EkoStore` opens a fixed path under Application Support, not an app-group container. Much cheaper
alternative: write a tiny short-lived JSON snapshot to a group container on each OTP commit and let the
widget read only that, sidestepping shared SQLite. Either way, think hard before putting a live 2FA code
on the lock screen — default it to tap-to-reveal.

---

## Working notes

<a id="working-notes"></a>

**A Linux container can build and test the Android side.** This is worth knowing, because it turns most
Android findings from "argued" into "verified":

```sh
# SDK
curl -O https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
# unzip into $ANDROID_HOME/cmdline-tools/latest, accept licences, then:
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"

# JDK 17 — required, see C-03. Ubuntu 24.04's openjdk-17 packages 404; use Temurin:
curl -L "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" | tar xz

echo "sdk.dir=$ANDROID_HOME" > android/local.properties
(cd android && ./gradlew :core:test testDebugUnitTest lintDebug assembleDebug)
```

**Swift can be syntax-checked, not built.** `swiftc -parse` from a Linux Swift toolchain catches syntax
errors across the whole macOS tree without needing AppKit — it does not resolve imports. It caught
nothing in this round but is cheap insurance for hand-written Swift:

```sh
for f in $(find macos -name '*.swift'); do swiftc -parse -suppress-warnings "$f" || echo "FAIL $f"; done
```

Everything beyond that — type checking, `swift test`, `xcodebuild` — needs a real Mac. **Every macOS
finding in this document is source-verified only**, and the AppKit-behaviour claims in particular
(window levels, key-equivalent dispatch, material blending, status-item metrics) should be confirmed on
hardware before being treated as settled.

**Vector drawables can be previewed.** `cairosvg` renders the same path data an Android
`VectorDrawable` uses, which is how #20's launcher icon was checked against the circle, squircle and
rounded-square masks and at 48 dp before it shipped. Worth repeating for any icon change.

**Repository CI was down throughout this work.** Every `ci.yml` run — on every branch, and on nine
Dependabot PRs that predate it — failed 3–5 seconds after creation with `runner_id: 0`, no steps
executed and no log blob. That is a job never picked up by a runner, i.e. an account- or org-level
Actions condition, not a workflow or code defect. Re-check before concluding anything from a red PR.
