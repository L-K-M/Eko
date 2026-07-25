# Eko — Review (Opus)

A full read of the code as it stands at commit `56b6796` ("Implement Eko v1"), covering
bugs, performance, interface, aesthetics, missing features, and ideas.

> **Baseline note.** This was written against `56b6796`. `2bf40dd` (PR #4) landed on `main`
> mid-review and resolved several build/CI/docs items; §H is annotated accordingly and
> nothing was silently dropped. Everything outside §H is unaffected — #4 touched no
> application code.

**How this was produced.** Ten independent review passes over the tree (macOS UI, Android UI,
macOS core correctness, Android core correctness, cross-platform performance, protocol/interop
conformance, security & privacy, product completeness, build/CI/docs, and idea generation), each
followed by an adversarial verification pass that tried to refute its own findings against the
source. Findings that could not be confirmed from the code were dropped. On top of that, the
Android project was actually built and tested in this environment (`assembleDebug`, `test`, `lint`
against a real SDK 36 + JDK 17 toolchain) so a subset of items below are machine-verified, not
just read. Swift could not be compiled here — no macOS toolchain — so every macOS finding is
source-verified only, and that is flagged where it matters.

**Overall.** This is a genuinely strong codebase. The durability core (phone outbox → per-Mac
cursor → ack-after-commit → honest gap spans), the commit-then-reveal pairing SAS, the exact-DER
pinning, the strict framing and the shared test-vector discipline are all better than what
comparable tools ship. The two hand-rolled protocol validators agree with each other on almost
everything. Where the project is weak is almost entirely *above* that line: the presentation
layer is a thin, literal rendering of the state machine underneath it, and it leaks the state
machine's vocabulary, its raw enums and its timing directly to the user. The single biggest gap
between what Eko *is* and what it *feels like* is that nobody has yet designed the surface.

Legend: **[V]** verified by building/running the toolchain here · **[S]** source-verified ·
severity `critical` / `high` / `medium` / `low` / `idea`.

---

## Top 12, in order

| # | ID | What | Why it's first |
| --- | --- | --- | --- |
| 1 | [M-01](#m-01) | The Mac app has no menu, so it cannot be quit and ⌘C/⌘V/⌘Q are dead | Users cannot exit the app or copy a code they selected |
| 2 | [P-01](#p-01) | A synchronous main-thread DB read per committed event | This is the stuttering; 2 000 blocking reads during one replay |
| 3 | [B-01](#b-01) | Capture writer's queue is discarded on listener teardown | Breaks the product's headline "nothing is lost" promise |
| 4 | [B-02](#b-02) | Reconnect backoff resets on every mDNS sighting | Continuous-radio hot loop; visible battery drain |
| 5 | [A-01](#a-01) | Android always lands on the setup checklist | Every launch, forever, even fully paired |
| 6 | [P-02](#p-02) | Foreground-service notification re-posted per mirrored event | Binder churn + NotificationManager rate-limiting on the battery path |
| 7 | [M-02](#m-02) | Panel is opaque, so its `.ultraThinMaterial` blurs nothing; traffic lights sit on the logo | The two most visible "unfinished port" tells on macOS |
| 8 | [B-03](#b-03) | `confirmPairing` doesn't retire the superseded generation | Can permanently wedge a peer with a PK constraint failure |
| 9 | [P-03](#p-03) | Status item redraws on every model change, through a double main-queue hop | Continuous CPU with the panel closed |
| 10 | [B-04](#b-04) | `AckAccumulator.flush` is reentrant; `lastSent` can regress | Duplicate ACKs, cursor regression |
| 11 | [M-03](#m-03) | Row actions are hover-gated and resize the row | Unreachable by keyboard/VoiceOver; list jumps under the pointer |
| 12 | [S-01](#s-01) | Unbounded inbound frame queue reachable pre-confirmation | LAN peer can OOM the Mac during the pairing window |

---

# A. Bugs

## macOS core

<a id="b-03"></a>
### B-03 · `confirmPairing` leaves the superseded generation un-retired — `high` [S]
`macos/Sources/EkoCore/EkoStore.swift:440,558`, `SessionManager.swift:141`

`beginSession` treats a generation change as a hard boundary: it inserts the old generation into
`retired_generation` and deactivates its notifications (`EkoStore.swift:558-575`). `confirmPairing`
performs the *same* generation change — overwriting `current_generation`, resetting
`processed_through_seq` — and does neither.

Reachable via `(.revoked, .pair)` → `runPairing` → `confirmPairing` (`SessionManager.swift:141`):
a device reaches `revoked_pending` with history intact through `requestUnpair` on a live session,
and if the user re-pairs from the phone instead of letting the unpair complete, G2 commits while
G1's rows survive un-retired. Two consequences: (1) every G1 `notification` row stays `is_active = 1`
forever, so the panel shows dead notifications as live and "Dismiss on phone" targets keys from a
dead generation; (2) a later `beginSession` announcing G1 passes the retired check, sets `cursor = 0`,
and the first `ingestEvent` at seq 1 hits the surviving `(device, G1, 1)` row's composite primary key
— a hard throw out of `runNormalLoop` **on every reconnect**, with no recovery short of "forget device".

**Fix:** make `confirmPairing` do the same generation-boundary work as `beginSession` when the
generation actually changes. Additionally make `beginSession` defensive: when it resets `cursor = 0`
for an incoming generation, assert no `event`/`gap_span` rows already exist for `(device, generation)`
so an unexpected rollback fails loudly at admission rather than wedging on the first insert.

<a id="b-04"></a>
### B-04 · `AckAccumulator.flush` is reentrant; `lastSent` can regress — `medium` [S]
`macos/Sources/EkoCore/SessionManager.swift:993,1013`

`AckAccumulator` is an actor, but `flush()` mutates `lastSent` *after* `await transport.send(...)`.
Actor reentrancy lets the 1-second timer and the 20-position threshold both pass the
`highestCommitted > lastSent` guard while the send is in flight. Both send. If the later-started
flush carries a higher sequence and completes first, the earlier one then writes the *lower* value
into `lastSent`, which regresses below what was actually transmitted, and the next flush re-sends
an already-acknowledged sequence.

Separately, the early `return` at the guard never resets `positionsSinceAck`, so once the counter
passes 20 it stays above threshold and `committed` calls `flush()` on *every* subsequent event
instead of batching — which quietly defeats the batching design during replay.

**Fix:** serialize the send behind an `isFlushing` flag or a single `Task` chain; write
`lastSent = max(lastSent, sequence)`; reset `positionsSinceAck` on the no-op path too.

### B-05 · Fetch responses that lose a race with a live removal strand the row permanently — `medium` [S]
`macos/Sources/EkoCore/EkoStore.swift:949,1005,1085,1717`

`reconcileActiveSnapshot` marks a stale key `body_complete = 0` and queues a fetch. The row is then
invisible, because `fetchNotifications` unconditionally requires `n.body_complete = 1`. The only
thing that clears the flag is `applyFetchEvent`, which bails early on
`guard stateSequence >= existingState else { return }`.

Concrete failure: backlog ends at H=100 with key K at `state_seq = 90` and a hash mismatch → K becomes
`body_complete = 0`, fetch sent. The user dismisses K on the phone; the `removed` event at seq 101
arrives first and sets `last_state_seq = 101`. The fetch response arrives carrying `state_seq = 90`,
fails `90 >= 101`, returns. K is stranded at `body_complete = 0` forever — never in the feed, never
in per-app settings, never repaired. A notification is silently lost from history even though the
event stream was fully committed and ACKed.

**Fix:** in `applyFetchEvent`, when the state has moved on but the row is still `body_complete = 0`
and the content hash matches, backfill body/app/search_text and set `body_complete = 1` without
regressing `last_state_seq` or `is_active`. Same for `applyFetchMissing`. Belt and braces: have prune
reap `body_complete = 0` rows with no outstanding fetch.

### B-06 · Accumulated active-snapshot has no ceiling — `medium` [S]
`macos/Sources/EkoCore/SessionStateMachine.swift:149,158`

`accept(.activeChunk)` appends every chunk into `activeEntries`/`activeKeys`. The per-chunk cap
(`maximumActiveEntriesPerChunk = 4 096`) is enforced, but nothing caps the *number* of chunks or the
accumulated total, and `activeSnapshotFinished` is only set when the peer sends `final = true` — which
the peer controls. With keys up to 8 KiB, a phone that never finalises grows the array and the `Set`
until the process dies. Post-TLS, so robustness rather than attack, but a wedged phone gets there as
easily as a hostile one.

**Fix:** track a running total and throw once accumulated entries or key bytes exceed a documented
ceiling; add the ceiling to `protocol/protocol.md` §9 so the phone knows it.

### B-07 · `NWListener .waiting` never resumes the start continuation — `low` [S]
`macos/Sources/EkoCore/TLSListener.swift:80`

`startListener(port:)` resumes its continuation from `.ready`, `.failed` and `.cancelled` but falls
through on `.waiting`. `NWListener` can sit in `.waiting` indefinitely (port held by another process,
Local Network permission not granted). When it does, `start(preferredPort:)` never returns,
`startWithPortFallback` never reaches its `catch`, the `.any`-port fallback never runs, and
`AppRuntime.start`'s task hangs — a permanently "starting" listener with no error and no recovery.

**Fix:** give `startListener` a deadline that resumes with `EkoCoreError.timedOut` and cancels the
listener, so the fallback path is reachable.

### B-08 · A paired peer can flip another device's UI state to failed by lying in `hello` — `low` [S]
`macos/Sources/EkoCore/SessionManager.swift:96,193`

`claimedDeviceID = hello.deviceID` is assigned at `:96`, *before* the identity check at `:98`. The
catch block then reports that unverified claim through `sink.connectionStateChanged`, which writes
straight into `AppModel.connectionStates` and drives the status glyph and device chips. Any peer TLS
admitted can mark an unrelated healthy device `.failed`. `finishSession` is safe (it compares transport
IDs); `connectionStateChanged` is not gated.

**Fix:** one-line — set `claimedDeviceID` only after the fingerprint check, or derive it from
`EkoCrypto.fingerprint(of: peerCertificateDER)`.

### B-09 · Event receipt rows grow without bound inside a long-lived generation — `low` [S]
`macos/Sources/EkoCore/EkoStore.swift:1483,1516`

`prune` strips payloads for the current generation but never deletes the rows, because the duplicate
check needs `kind`/`notification_key`/`content_hash` to stay idempotent. The reasoning is sound; the
effect is a `WITHOUT ROWID` table growing monotonically for the life of a pairing, with retained
`notification_key` up to 8 KiB per row.

**Fix:** bound the receipt window — below max(Mac retention, phone's 48 h/2 000 outbox window) the
coverage guarantee is unnecessary. Delete older receipts and record one definitive `gap_span` covering
the deleted range so the event-or-gap coverage invariant still holds. Or hash the key into a
fixed-width column on prune.

## Android core

<a id="b-01"></a>
### B-01 · Capture writer's queue is discarded on listener teardown — `critical` [S]
`android/capture/.../EkoNotificationListener.kt:106-112`, `SerializedNotificationWriter.kt:117-133`

`SerializedNotificationWriter.close()` does `channel.close()` — a *graceful* close whose contract is
that the consumer keeps draining. `SerializedNotificationWriterTest:38-43` asserts exactly that. The
production caller violates it:

```kotlin
writer.close()
scope.cancel()   // kills the consumer immediately
```

Every `CaptureCommand` still in the 256-slot channel is discarded without reaching Room, and the
command executing inside `RoomCaptureSink` is cancelled mid-`withTransaction`, rolling it back. This
directly breaks "persist durably at post time *before* any send attempt" — `onNotificationPosted`
already returned success to the system for those notifications.

Triggers: any NLS teardown with a non-empty queue — `supportedRebind()` (the repair flow, HealthWorker,
unpair), `MY_PACKAGE_REPLACED` on app update, the user toggling notification access, a system rebind.
A notification burst plus a slow `synchronous=FULL` write is exactly when the queue is deepest.

Worse, the loss is invisible to the gap machinery: `onListenerDisconnected` records a suspected gap
covering the *disconnect interval*, but the dropped commands were posted *before* the disconnect, so
they are reported as neither delivered nor gapped.

**Fix:** `suspend fun closeAndJoin() { channel.close(); worker.join() }`, and in `onDestroy` do a
bounded `runBlocking(NonCancellable) { withTimeout(1_500) { writer.closeAndJoin() } }` before
`scope.cancel()`. If the drain times out, commit a gap bounded by the accepted-but-unprocessed
ordinals so the loss is at least reported.

<a id="b-02"></a>
### B-02 · Reconnect backoff resets on every mDNS sighting — `high` [S]
`android/transport/.../ConnectionService.kt:144-152,170-185`

```kotlin
backoff.recordStableConnection(...)
if (refreshEndpointFromDiscovery(deviceId)) { backoff.reset(); continue }
```

`refreshEndpointFromDiscovery` returns `true` whenever mDNS resolves *any* `_eko._tcp` service whose
`fp` matches — it never compares the discovered endpoint to the stored one. So it returns `true` on
every attempt as long as the Mac is advertising, even when nothing changed.

Whenever the Mac is discoverable but unreachable (Mac app starting, listener not yet bound, port
firewalled, admission revoked, `validateWelcome` rejecting), the loop becomes: connect fails fast →
discovery finds the Mac in well under 5 s → `backoff.reset()` → `continue` → retry immediately.
`FullJitterBackoff` never grows because `attempt` is zeroed every pass. Each iteration also acquires
and releases a `WifiManager` multicast lock, starts and stops `NsdManager` discovery (which caps
concurrent requests per app and can wedge under churn), and does a DataStore write via `updateEndpoint`
even though nothing changed — which re-emits `identityStore.state` and re-runs `reconcileJobs`.

That is a continuous-radio, continuous-disk hot loop.

**Fix:** compare `PeerEndpoint(match.host, match.port)` with the stored endpoint and only
`reset()`/`continue` (and only write) if it differs. Apply the backoff delay *before* the discovery
probe so a discoverable-but-unreachable Mac still backs off.

### B-10 · Swiping the app from Recents permanently pauses forwarding — `high` [S]
`android/app/.../EkoApplication.kt:129-154`, `android/transport/src/main/AndroidManifest.xml:12`

`blockStartsAfterUserStop()` and `recordProcessExitEvidence()` both treat
`ApplicationExitInfo.REASON_USER_REQUESTED` as "the user deliberately stopped Eko" and latch
`setStartBlocked(true)` / `setForwardingPaused(true)`. PLAN.md:1288 justifies this for a Task-Manager
stop, but the AOSP constant is broader: it also covers **the user removing the app from Recents**.
Swiping Eko away — an ordinary gesture, and on several OEM ROMs it does kill the process — silently
and permanently disables the product's only function. It also contradicts the transport manifest,
which sets `android:stopWithTask="false"` precisely so the connection survives task removal.

Most reachable path: during onboarding, before any peer exists, no foreground service is holding the
process up. Open Eko → swipe it out of Recents → reopen → next `onCreate` sees `REASON_USER_REQUESTED`
→ `forwardingPaused = true` persists → the user finishes pairing and the transport never starts.

**Fix:** require corroborating evidence before latching — e.g. only latch when the process had a
running foreground service at exit (record an "fgs active" marker in prefs, clear it in `onDestroy`),
or when `getImportance()` indicates it was not a cached/background task removal. And make the
resulting state a *visible, dismissible* banner with a Resume button rather than a silent global pause
(see [A-07](#a-07)).

### B-11 · Per-app "include ongoing" cannot work on Android 13+ — `medium` [S]
`android/capture/src/main/AndroidManifest.xml:12-14`, `EventRepository.kt:416-419`, `EkoScreens.kt:572`

The listener declares `default_filter_types="conversations|alerting|silent"`, omitting `ongoing`. On
API 33+ that sets the listener's filter in NotificationManagerService, so ongoing notifications are
never delivered to `onNotificationPosted` and never appear in `getActiveNotifications()`. Meanwhile
the app ships a live per-app override for exactly those notifications (`shouldForward` honours
`rule?.includeOngoing`, and the Apps screen renders a switch for it). On API 33+ that switch is inert;
on API 26–32 it works. There is no public API to widen the filter from the app.

**Fix:** either add `ongoing` to `default_filter_types` and rely solely on the app-side `shouldForward`
filter (which already implements the documented default), or hide/disable the switch on API 33+ and
explain via `getCurrentListenerFilter()` that the user must widen it in system settings.

### B-12 · `mainHandler.removeCallbacks(::enqueueReconciliation)` removes nothing — `medium` **[V]**
`android/capture/.../EkoNotificationListener.kt:102-108,129-135`

Each evaluation of `::enqueueReconciliation` SAM-converts to a *fresh* `Runnable`; `removeCallbacks`
matches by reference identity. So `onDestroy` allocates a new object and removes nothing. A retry armed
at `:133` (up to 3, 5 s apart) still fires after the service is destroyed, running against a torn-down
listener: `activeNotifications` throws (caught → null) → `reconciliationFailed()` → possibly re-arms,
and any `writer.gap(...)` now hits a closed channel, bumping the overflow counter (with a synchronous
`SharedPreferences.commit()`) into a writer that will never flush it. Net effect: bogus "writer
overflow" and "reconciliation failure" counters in Diagnostics after every rebind.

**Verified by the toolchain:** Android Lint flags this exact line —
`EkoNotificationListener.kt:108: Implicit new Runnable instance being passed to method which ends up
checking instance equality [ImplicitSamInstance]`.

**Fix:** hold one `private val reconcileRunnable = Runnable { enqueueReconciliation() }` and post/remove
that instance.

### B-13 · A stalled TCP write disables the heartbeat's own liveness check — `medium` [S]
`android/transport/.../TlsConnector.kt:67-72`, `NormalPeerSession.kt:106-120`

After the handshake the socket is fully blocking (`soTimeout = 0`), so liveness rests entirely on the
heartbeat. But the heartbeat arms its deadline *after* the write:

```kotlin
pendingPing.set(ping)
outbound.send(WireJson.ping(...))   // suspends until the frame is actually written
delay(PONG_DEADLINE_MS)
if (...) { socket.close(); throw ... }
```

`OutputStream.write` on a socket has no timeout in Java. If the peer stops draining (Mac wedged, app
suspended mid-transfer, an AP silently blackholing the flow so the TCP window never reopens), the write
blocks indefinitely, the deadline check is never reached, the reader is blocked in a timeout-less
`read`, and the live-stream collect is blocked behind the same actor. The session wedges permanently
with no error and no reconnect until OS TCP keepalive (2 h default). `ConnectionService` never cancels
a running session on network change either — `networkMonitor.changes` is only consulted *between*
attempts.

**Fix:** arm the pong watchdog *before* calling `outbound.send`
(`launch { delay(PONG_DEADLINE_MS); if (pendingPing.get() == ping) socket.close() }`), and have the
peer job observe `networkMonitor.networks` and close the socket when its `Network` stops being eligible.

### B-14 · `startForeground` failures crash the process instead of degrading — `medium` [S]
`android/transport/.../ConnectionService.kt:50-63,239-242`

`requestStart` carefully wraps `startForegroundService` in `try/catch (RuntimeException)` to survive
`ForegroundServiceStartNotAllowedException`. The deferred half of that check lives on the
`Service.startForeground()` side and is unguarded: `onCreate` calls `showForeground(...)` directly, and
the state collector calls it from inside `scope.launch { }` whose `SupervisorJob` prevents sibling
cancellation but does **not** swallow the exception — it reaches the default uncaught handler and kills
the process.

The same shape appears in `EkoApplication.kt:108-118`: the catch is `SQLiteException` only, while
`DurabilityCallback.onOpen` deliberately throws a plain `IllegalStateException` when WAL/`synchronous=FULL`
cannot be established. So the app records `StoreDurability.Unhealthy` *for the Diagnostics UI* and then
crashes anyway — the health state can never be shown.

**Fix:** `runCatching` around `showForeground` with a `TransportRuntime.log` + `stopSelf()` fallback;
broaden `EkoApplication`'s catch to `Throwable`.

### B-15 · Event-store failure in the ViewModel crashes the app — `high` [S]
`android/app/.../EkoViewModel.kt:85-99`

`repository.observeMetadata().onStart { emit(repository.initialize()) }` is folded into
`combine(...).stateIn(viewModelScope, ...)` with no `.catch {}`. `initialize()` is exactly the call
`EkoApplication` already treats as throwing. In the ViewModel there is no guard, and `viewModelScope`
has no `CoroutineExceptionHandler`, so the exception kills the process. `apps` has the same exposure.

The result inverts the design intent: on the one occasion the user most needs the Diagnostics screen
("Event store — Unhealthy: …"), the app force-closes on launch instead of showing it. The
Application-side recovery runs async on `Dispatchers.IO` and races the ViewModel, so it does not
reliably win.

**Fix:** `.catch { }` into an explicit `HomeState.StoreUnavailable` / `AppsState.Error` and render a
first-class in-app error state wired to the existing `EventStoreResetter` path.

### B-16 · Nothing survives rotation — `high` [S]
`android/app/.../EkoScreens.kt:117,211-214,478`, `MainActivity.kt:54-55`

`rememberSaveable` is used exactly **zero** times in the app module, and `MainActivity` declares no
`android:configChanges`. Every rotation, fold, dark-mode switch or font-size change discards: the typed
host / port / fingerprint / token (a manually entered IP and a 64-hex fingerprint, wiped mid-entry;
`port` also resets to "48808"), the current tab, the in-flight unpair confirmation dialog, and
`scannerVisible`/`scannerError`. The pairing state itself lives in the ViewModel and survives — which
makes it worse, not better: the SAS verify dialog reappears over a blank form.

**Fix:** `rememberSaveable` for all four fields, `page`, `scannerVisible`, `scannerError`; store the
unpair target as a `String` deviceId and resolve at render time. A handful of one-word edits.

### B-17 · `peerJobs.computeIfAbsent` can recursively mutate the same key — `low` [S]
`android/transport/.../ConnectionService.kt:86-96`

`Job.invokeOnCompletion` runs the handler **synchronously on the calling thread** if the job already
completed — which happens whenever `scope.launch` returns an already-cancelled job. `peerJobs.remove(id, job)`
then runs inside `computeIfAbsent`'s mapping function, for the very key whose bin is locked.
`ConcurrentHashMap`'s contract forbids this; against the `ReservationNode` that `computeIfAbsent`
installs, `replaceNode` never validates and spins in its retry loop — an unbounded busy-loop on a
`Dispatchers.IO` thread rather than a clean failure. `reconcileJobs` is also entered concurrently from
two coroutines with no mutual exclusion.

**Fix:** create the job, `putIfAbsent` it, then register `invokeOnCompletion`; or serialize
`reconcileJobs` behind a `Mutex` and use a plain `HashMap`.

## Protocol / interop

### B-18 · The Mac imposes an undocumented 30 s deadline inside the 300 s pairing window — `high` [S]
`macos/Sources/EkoCore/SessionManager.swift:656,682,694`, `LanPairingClient.kt:361`

`protocol.md:307` defines exactly one pairing deadline: an attempt expires 300 s after its first
accepted `pair hello`. The phone implements that faithfully (`PAIRING_WINDOW_MS = 5 * 60_000`) and
leaves its confirm sheet up for the whole window. The Mac adds a second, much shorter one: it blocks
unboundedly on the *local* user's approval sheet, then applies a fixed 30 s per-frame receive deadline
to the phone's `pair_result`. A user who takes longer than 30 s to press Confirm on the phone — while
the Mac's own sheet imposes no such limit — gets a failure the protocol says should not happen.

**Fix:** derive the Mac's per-frame receive deadlines from the attempt's remaining lifetime, floored at
some minimum, so both endpoints enforce the one 300 s window. If a shorter deadline is deliberate for
non-interactive steps, document it and scope it to those steps.

### B-19 · The phone ignores `error{unpaired}` / `error{stale_generation}` and reconnects forever — `high` [S]
`NormalPeerSession.kt`, `SessionManager.swift:869,959`

The Mac sends these as fatal, terminal signals. The phone logs and falls back into its ordinary
reconnect loop, so a device the Mac has revoked keeps dialling indefinitely. The user-visible symptom
is a phone that says "Reconnecting" forever with no explanation and no path to re-pair.

**Fix:** map the terminal error codes onto distinct `PeerTransportState`s that stop the retry loop and
surface an actionable card ("This Mac no longer recognises this phone — pair again").

### B-20 · Mac measures pairing/QR expiry on the wall clock; the protocol requires monotonic — `medium` [S]
`macos/Sources/EkoCore/PeerAdmission.swift`, `EkoStore.swift`

`protocol.md` specifies monotonic measurement and Android uses `elapsedRealtime()`. The Mac uses `Date`,
so an NTP step or a manual clock change during a pairing window can expire an attempt early or extend it.

**Fix:** add a monotonic reading to `EkoClock` (backed by `ContinuousClock`) and express both the
pairing-attempt and QR-token deadlines as monotonic deltas, keeping `Date` for display and the
persisted-attempt reboot check. Also cap `activate(duration:)` at 300 s to match `protocol.md:217`.

### B-21 · The phone accepts `ack{seq:0}`, which the shared malformed vector requires it to reject — `medium` [S]
The ack vectors are only exercised against the side that never receives acks, so the gap is invisible
to CI. Fix the validator and run the vector against both sides.

### B-22 · `unpair_ack` is unreachable in every state on the phone — `low` [S]
`SessionInboundValidator.kt:82,98-103`

`RESTRICTED_UNPAIR_TYPES` correctly lists `unpair_ack`, but `validateControl` has no branch for it and
it is also a member of `OTHER_STATE_TYPES`, whose catch-all throws. A frame that passes the state gate
is rejected two lines later by the type gate. The Mac accepts it in any non-closed phase. Latent today;
a correctness trap the moment either side starts sending it in a new state.

### B-23 · `ext_types` can never be negotiated — `low` [S]
The Mac advertises it in `localCapabilities` and honours it in `SessionStateMachine`; the phone never
advertises it (`WireJson.capabilities = listOf("notif", "dismiss", "otp_context")`), and `welcome.caps`
is the intersection. So the protocol's sole forward-compatibility escape hatch is dead, and the
`unknown-json-type-with-extension-capability` vector's `ignore` outcome is unreachable in practice.
Adding one string makes several of the ideas in section J shippable without a breaking change.

### B-24 · `error.code` enum is enforced only by the Mac — `low` [S]
`error.schema.json` constrains `code` to thirteen values and the Mac enforces it; the phone accepts any
string in both `SessionInboundValidator` and `parseTombstoneInbound`.

### B-25 · The phone closes the pairing socket after `welcome` instead of continuing into sync — `low` [S]
`protocol.md:338` ends pairing with "the connection then follows normal sync", and the Mac does exactly
that — sends `welcome`, falls into `runNormalLoop`, and waits 90 s for `backlog_start`. The phone reads
`welcome`, validates it, and unconditionally closes the socket in `confirm`'s `finally`. So the first
post-pairing sync always costs a wasted Mac-side session plus a full reconnect.

### B-26 · The phone sends a different `device_name` in pair vs. normal hello — `low` [S]
Pairing sends `Build.MODEL`; every later hello sends `"${Build.MANUFACTURER} ${Build.MODEL}"`, and the
Mac persists whatever arrives. The user confirms "Pixel 8" in the pairing sheet and then watches the
chip rename itself to "Google Pixel 8". One shared `localDeviceName()` fixes it.

---

# B. Performance & stuttering

This is where the user-visible "feels slow" lives. The chain is consistent on both platforms: a
high-frequency state source drives an unfiltered observer, which does synchronous I/O, which
invalidates the whole UI.

<a id="p-01"></a>
### P-01 · A synchronous main-thread DB read per committed event — `critical` [S]
`macos/App/AppSessionSink.swift:30-38`, `AppModel.swift:358`

`AppSessionSink.eventCommitted` runs for **every** non-duplicate ingested event, including every
replayed backlog event, and does three expensive things per event:

1. `store.device(id:)` — a `pool.read` per event, for a value constant for the whole session.
2. `await model?.refreshGaps()` — `AppModel` is `@MainActor` and `refreshGaps()` is a **synchronous
   GRDB `pool.read` of up to 100 rows on the main thread**, followed by an unconditional assignment to
   a `@Published` property, which invalidates the entire SwiftUI tree *and* the status item.
3. `diagnostics.record(.debug, ...)` with an eagerly-built interpolated string — one actor hop per event.

For the design's own stress case (2 000-event replay): 2 000 background reads, 2 000 blocking
main-thread reads, 2 000 full SwiftUI invalidations, 2 000 actor hops. The gap set almost never changes
during replay, and `refreshGaps()` is called unconditionally regardless of `outcome.kind`.

Note that `NotificationCoordinator.handleCommittedEvent` correctly early-outs on
`guard !outcome.duplicate, !outcome.replayed` — the sink does its work *before* that guard applies.

**Fix:** resolve the device name once at session negotiation; coalesce `refreshGaps()` behind a
~250 ms debounce (or only run it for `.captureGap`); make it async off the main actor; drop the
per-event debug record to a counter flushed at `backlogCompleted`.

<a id="p-03"></a>
### P-03 · Status item redraws on every `objectWillChange`, through a double main-queue hop — `high` [S]
`macos/App/StatusPanelController.swift:82-125`

```swift
model.objectWillChange
    .receive(on: RunLoop.main)
    .sink { DispatchQueue.main.async { self?.updateStatusItem() } }
```

The nested-hop antipattern, with no `removeDuplicates` and no throttle, subscribed to a publisher that
fires on every feed delivery, every device/preference delivery, every `setConnectionState`, every
`refreshGaps()` (i.e. per committed event) and the 60 s `now` tick. Each run then does a linear scan of
up to 400 notifications that **allocates a fresh `Date()` inside the closure body, per element**, and
constructs a brand-new `NSImage(systemSymbolName:)` that it assigns unconditionally, forcing a
status-bar redraw even when the symbol is unchanged.

Symptom: the menubar glyph churns and the app burns main-thread CPU during replay — continuous
background load even with the panel closed.

**Fix:** derive a small `Equatable` state struct from just
`(bannersPaused, deviceCount, connectionStates, hasRecentCode)`, `.removeDuplicates()`,
`.throttle(250 ms, latest: true)`, one sink, no inner async. Hoist the cutoff `Date` out of the
predicate. Cache the four images and skip the assignment when unchanged.

### P-04 · Every feed row observes the whole `AppModel` and builds its own formatter — `high` [S]
`macos/App/PanelViews.swift:292-293,396-400`

`NotificationRow` declares `@ObservedObject var model: AppModel` and is constructed per element, so
every visible row subscribes to the model and is invalidated by *any* published change — including the
`now` tick and per-event `refreshGaps()`. The model is used only for four callbacks and `model.now`.

Compounding it, `relativeDate(_:)` constructs a **new `RelativeDateTimeFormatter` on every call** —
once per row per body evaluation. `Formatter` subclasses are expensive to instantiate (locale/calendar
resolution); this is the classic per-row-per-frame formatter allocation.

**Fix:** pass plain closures plus `now: Date` as a value and make the row `Equatable` so SwiftUI can
skip unchanged rows; hoist the formatter to a `static let`.

### P-05 · Feed observation is a full scan + temp sort + correlated subquery, re-run on every write — `high` [S]
`macos/Sources/EkoCore/EkoStore.swift:801,1701-1743,1793`, `AppModel.swift:362,408`

Four compounding problems:

- **Every committed event dirties the `device` table** (`UPDATE device SET processed_through_seq = ?,
  last_seen_ms = ?`), and both live `ValueObservation`s read `device`, so GRDB's tracked region is
  invalidated by every single ingest — including `removed` and `capture_gap`.
- **The query can't use an index in its default configuration.** `ORDER BY n.received_at_ms DESC` has
  only `notification_received_idx (device_id, received_at_ms DESC)` available, which is unusable for a
  global ordering when no `device_id` predicate is present — the default panel state. `notification` is
  `WITHOUT ROWID`, so this is a full scan plus a temp b-tree sort, with `LIMIT` applied only after.
  Search adds a leading-wildcard `LIKE`, so the search index can't help either.
- **Each surviving row pays a correlated subquery** for its latest OTP.
- **`observeAppPreferences` runs an unconditional full scan + GROUP BY** of the whole notification table
  on the same trigger.
- **None of it stops when the panel is closed.** `panelVisibilityChanged` only cancels the relative-time
  ticker.

So during a 2 000-event replay with the panel closed, GRDB runs ~4 000 whole-table scans, each
assigning a fresh 400-element array to `@Published`, each re-triggering the status item.

**Fix:** add `CREATE INDEX notification_recent_idx ON notification(received_at_ms DESC)`; drop
`last_seen_ms` out of the per-event `UPDATE` (write it at session start/end and on a coarse timer);
suspend the feed observation when the panel hides; throttle observation delivery ~150 ms; consider a
denormalized `latest_otp_id` column maintained at ingest.

### P-06 · `AsyncThrowingStream`'s unbounded outer buffer defeats `bufferingNewest(1)` — `medium` [S]
`macos/Sources/EkoCore/EkoStore.swift:1146,1166,1217`

All three observation wrappers correctly coalesce GRDB's notifications with `.bufferingNewest(1)` — and
then yield into an `AsyncThrowingStream` constructed **without** a buffering policy, which defaults to
`.unbounded`. `continuation.yield` never suspends, so the pump drains GRDB as fast as it produces and
stacks every snapshot. The MainActor consumers then walk through every stale snapshot in order instead
of jumping to the latest — exactly what `bufferingNewest(1)` was meant to prevent.

**Fix:** one word, three times: `AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { ... }`.

### P-07 · `AppModel` does synchronous GRDB reads *and writes* on the main actor — `medium` [S]
`macos/App/AppModel.swift:197,252,272,285,359`

`focus` runs the expensive 500-row feed query synchronously on the main thread from the banner-click
handler. `copyCode` → `markOTPCopied`, `toggleStar` → `setStarred`, `updatePreference` →
`setAppPreference` are all `pool.write` calls, and `EkoStore` sets `busyMode = .timeout(5)`, so any of
them can block the main thread for up to **five seconds** behind an in-flight ingest write.

**Fix:** GRDB `asyncRead`/`asyncWrite`, hopping back to `@MainActor` only to publish. Add a keyed
`notification(deviceID:key:)` store lookup so `focus` stops scanning 500 rows for one key.

### P-08 · Inbound message queue is unbounded with an O(n) dequeue — `medium` [S]
`macos/Sources/EkoCore/NetworkTransport.swift:162,174,191,221`

`MessageInbox` buffers into a plain `[WireMessage]` with no cap, and `receiveNext()` re-arms
unconditionally, so TCP flow control never engages. The consumer is far slower (an fsync per event).
Peak memory tracks the whole backlog rather than a small window, and `messages.removeFirst()` on a Swift
`Array` is O(n) — draining n messages one at a time is O(n²), millions of element moves inside the lock
for n in the low thousands. See also [S-01](#s-01), which is the security-facing half of the same defect.

**Fix:** bound the buffer (~64 frames / a few MiB), stop re-arming above the high-water mark, resume from
`next()`, and use a head-index ring or `Deque` for O(1) dequeue.

### P-09 · OTP extraction allocates one `String` per Unicode scalar over up to 512 KB — `medium` [S]
`macos/Sources/EkoCore/OTPExtractor.swift:81,89,193-204`

`normalizeDigits`'s `default` branch — the overwhelming majority of characters — wraps each scalar in a
heap-allocated `String`, then a `Character`, producing an intermediate `[Character]`. It runs on the
**full** joined text; the `String(text.prefix(1_000))` cap is applied only *after* `normalizeDigits`,
`stripRetrieverArtifacts` (itself a full-text split/join/replace) and `extractOriginBoundCode` have all
run. The wire limits permit `BIG_TEXT_BYTES = 65_536` and `TOTAL_BODY_STRING_BYTES = 524_288`, so one fat
notification drives ~500k transient allocations. `extract` runs on the `SessionManager` actor's executor,
so a slow extraction directly delays the next commit and ACK during replay.

**Fix:** apply the 1 000-character cap *first*; rewrite `normalizeDigits` to build into a reserved
`String` appending `Character(UnicodeScalar)` directly, and short-circuit to `return input` when no
scalar is in the Arabic-Indic ranges (the common case).

### P-10 · Launch does DB migration, Keychain and a synchronous read on the main thread — `medium` [S]
`macos/App/AppDelegate.swift:53,102-103`, `AppModel.swift:396`, `StatusPanelController.swift:29,167`

`AppRuntime()` is constructed synchronously on the main thread and performs: `EkoStore(path:)` (directory
creation, pool open, `PRAGMA synchronous = FULL` verification round-trips, 7 migrations),
`loadOrCreateIdentity()` (Keychain I/O, and on first launch **P-256 key generation plus a self-signed
certificate mint**), and `refreshGaps()` (a synchronous `pool.read`). Then `StatusPanelController.init`
eagerly builds *both* hosting views, including a 720×560 Settings window the user may never open — whose
SwiftUI tree nonetheless subscribes to `AppModel` and is invalidated by every publish for the process
lifetime.

This app is designed to launch at login, so this is the first thing a user experiences.

**Fix:** show the status item first with a placeholder glyph, build store/identity in a detached task;
make `SettingsWindowController` construct its window lazily on first `show()`.

### P-11 · QR image regenerated by `CIFilter` on every body evaluation — `medium` [S]
`macos/App/PanelViews.swift:441,534-554`

`QRCodeView.body` calls `makeImage()` directly — construct filter, encode payload, 10× transform, build
`NSCIImageRep` + `NSImage` — with no `@State` and no memoization. `PairingView` holds
`@ObservedObject var model: AppModel`, so it is invalidated by every publish; during pairing the model
publishes continuously. The payload is fixed for the invitation's lifetime.

**Fix:** `@State private var image: NSImage?` populated in `.task(id: payload)`, or render once in
`AppModel.beginPairing()` alongside `qrPayload`.

<a id="p-02"></a>
### P-02 · Android foreground-service notification re-posted per mirrored event — `high` [S]
`android/transport/.../ConnectionService.kt:60-62,206-242`, `NormalPeerSession.kt:132,170`

`onCreate` installs `TransportRuntime.state.collect { showForeground(buildNotification(it)) }`.
`TransportRuntime.state` changes on essentially every mirrored notification: `forwarded()` writes
`System.currentTimeMillis()` into `lastForwardWall` (so the value is always distinct), and
`Connected(connectedAtWall, control.seq)` is republished on every inbound ACK. Roughly two emissions
per notification, each running the full `buildNotification()` path — a `getLaunchIntentForPackage`
binder call, two `PendingIntent` creations (each an AMS round-trip), a builder pass, and a
`startForeground` binder call into NotificationManagerService — for a notification whose rendered text
depends only on `paused` and the connected count and therefore almost never changes.

Consequences: sustained binder + wakelock churn precisely while mirroring (the battery-sensitive path),
and NotificationManagerService's ~5/s per-package enqueue rate limiter starts dropping updates.

**Fix:** derive a small display model, `.distinctUntilChanged()`, and cache the `PendingIntent`s in fields.

### P-12 · `TransportRuntime.update` is a non-atomic read-modify-write — `medium` [S]
`android/transport/.../TransportRuntime.kt:43-46`

```kotlin
private inline fun update(transform: (TransportSnapshot) -> TransportSnapshot) {
    mutable.value = transform(mutable.value)
}
```

Called concurrently from multiple peer jobs, the reconnect loop, and `log()` — all on `Dispatchers.IO`.
Concurrent updates lose writes: two peers transitioning at once can drop one peer's state, and log lines
disappear. `MutableStateFlow.update { }` exists precisely for this and is a one-line change. (The file
also carries an unused `AtomicReference` import, suggesting this was once intended to be atomic.)

### P-13 · Home screen state recomputes per captured notification, with an N+1 query — `high` [S]
`android/app/.../EkoViewModel.kt:85-97`

`metadata` is a Room `Flow` whose `last_assigned_seq` advances on **every committed event**, so the
`combine` transform re-runs per capture. Inside it:

```kotlin
peers = identity.confirmedPeers.sortedBy(...).map { peer ->
    val cursor = runCatching { repository.pairingRows().firstOrNull { it.pairingId == peer.deviceId } }
```

`pairingRows()` is `SELECT * FROM pairing_cursor` — called **once per peer** and then linearly searched
for that one peer. A textbook N+1 that re-queries the same table N times, plus a `sortedBy` allocation
and fresh `HomeState`/`HomePeer` objects per emission, delivered to `collectAsStateWithLifecycle`. With
`viewModel` also passed as an unstable parameter, `HomeScreen` cannot skip recomposition.

Symptom: the Home tab recomposes at the notification rate with a DB query per peer per notification —
the phone UI stutters exactly when the app is most likely to be open.

**Fix:** hoist to `pairingRows().associateBy { it.pairingId }` once per emission; debounce the driving
flow (`metadata.map { it.lastAssignedSeq }.distinctUntilChanged().sample(500)`); better still, combine
`repository.observePairings()` (which already exists) as a flow rather than reading imperatively inside
the transform.

### P-14 · Extraction and reconciliation run on the listener's main thread with uncached `PackageManager` lookups — `high` [S]
`android/capture/.../NotificationExtractor.kt:95-107`, `EkoNotificationListener.kt:65-75,118-137`

`NotificationListenerService` callbacks arrive on the process main looper, shared with Compose. Per
notification, `extract` does two binder round-trips to PackageManagerService (`getApplicationInfo` +
`getApplicationLabel`, no cache) and a `Resources.getSystem().getIdentifier(...)` by-name lookup — an API
explicitly documented as slow — plus a MessagingStyle Bundle walk and a sanitizer that calls
`value.toByteArray(UTF_8).size` repeatedly over a 64 KiB `bigText`, allocating a full byte array per
measurement.

The amplified case is reconciliation: `enqueueReconciliation()` runs that pipeline over **every** active
notification in one main-thread pass. On a phone with 40–60 active notifications that is 80–120 binder
calls plus 40–60 `getIdentifier` lookups in a single frame. And it is user-triggered:
`EkoViewModel.updateRule` calls `reconcileActive()` whenever a rule is enabled — so flipping a toggle in
the Apps list stalls the UI thread.

**Fix:** cache the redaction marker in a `by lazy` (it never changes for the process); cache labels in a
small `LruCache` invalidated on `ACTION_PACKAGE_*`; move the mapping loop off the callback thread.

### P-15 · `BootAwareClock.now()` does a synchronous `SharedPreferences.commit()` per event, inside the write transaction — `medium` [S]
`android/outbox/.../BootAwareClock.kt:17-23`, `EventRepository.kt:394-416`

Because wall time advances, `clampedWall != previousWall` is true on essentially every call, so every
`now()` performs a `commit()` — a full synchronous XML rewrite plus fsync. `now()` is called at least
twice per captured notification, and both calls happen *inside* `database.withTransaction { }` on a
database deliberately configured `synchronous=FULL`. So each notification pays its own fsync plus two
more, tripling the durable-write cost and lengthening exactly the window that makes the 256-slot writer
queue overflow.

**Fix:** keep the monotonic watermark in memory; persist lazily (only when it advances past the last
persisted value by ~30 s) with `apply()`, plus an explicit flush at teardown.

### P-16 · Backlog replay materializes the entire outbox twice — `medium` [S]
`android/outbox/.../EventRepository.kt:203-232`, `NormalPeerSession.kt:96-98`, `WireJson.kt:66-92`

`backlog()` runs entirely inside one `withTransaction` and loads the whole replay window with no paging
— up to 2 000 rows, each carrying its full `payload_json`. `WireJson.backlog` then eagerly decodes and
re-encodes **every** event into a `List<JsonObject>` (a `LinkedHashMap` of boxed primitives, typically
5–10× the source string) held simultaneously, and `sendBatch` receives the entire list as one command.
`snapshot` stays reachable for the whole send because `TransportRuntime.peer(..., Syncing(size))` and
the enclosing scope hold it.

Two consequences: a multi-megabyte heap spike and GC pauses in the foreground service (OOM risk on
low-RAM devices), and — because the whole read is one Room transaction — **the capture writer is blocked
behind it**, so live notifications are not committed until the snapshot closes.

`boundedActiveChunks` compounds it: it re-serializes the whole candidate chunk just to measure it, O(n²)
in bytes over up to 4 096 entries.

**Fix:** page the replay through the existing `eventsAfter(afterSeq, limit)` in ~100-event chunks, sending
and dropping each before fetching the next; keep only the metadata/high-water read inside a transaction;
accumulate encoded size incrementally in `boundedActiveChunks`.

### P-17 · Retention and pruning re-scan the whole outbox on the capture hot path — `medium` [S]
`android/outbox/.../EventRepository.kt:258-301,468`, `Daos.kt:42`

- `applyRetention` materializes every pending row **payloads included** to compute two integers, and
  `RoomCaptureSink.maintainRetention` invokes it per pairing every 32 commits — allocating the whole
  backlog's JSON strings every 32 notifications, purely as GC churn.
- `prunePhysicalRows()` is a full-table-scan DELETE with a correlated subquery, run on **every ACK**. The
  Mac batches acks at 20 events / 1 s, so a 2 000-event replay is ~100 ACKs × 2 000 rows ≈ 200k row
  visits inside write transactions contending with the capture writer.
- `pairingQueueDepth` counts by materializing rows.

**Fix:** add projection DAO queries (`SELECT seq, created_* …` for retention, `SELECT COUNT(*)` for depth);
bound the prune to `DELETE FROM outbox WHERE seq <= :minRetainedSeq` (an index-range delete) and run it on
the same 32-commit cadence rather than per ACK.

### P-18 · `Application.onCreate` and every `onResume` do binder IPC and blocking prefs I/O on the main thread — `medium` [S]
`android/app/.../EkoApplication.kt:27,53`, `EkoViewModel.kt:109,115`, `MainActivity.kt:45`

The heavy bootstrap is correctly on `Dispatchers.IO`, but `blockStartsAfterUserStop()` is called
*outside* it, synchronously in `onCreate`, on every process start including boot-receiver and
foreground-service starts. It does `getHistoricalProcessExitReasons` (a binder call into AMS) and a
first `getSharedPreferences` read (blocking XML parse).

`refreshSystemChecks()` is a synchronous function doing five system round-trips —
`isManagedProfile`, `isNotificationListenerAccessGranted`, `checkSelfPermission`,
`isIgnoringBatteryOptimizations`, `isLocationEnabled` — plus another prefs read. It runs from the
ViewModel's `init` and from `onResume` on **every** resume, which is precisely the onboarding flow where
the user bounces to Settings and back repeatedly.

**Fix:** move `blockStartsAfterUserStop()` into the existing `applicationScope.launch { }`; make
`refreshSystemChecks()` a `viewModelScope.launch(Dispatchers.IO)` assigning at the end; hoist
`CdmAssociationController` to a field.

### P-19 · Group-by-device does O(devices × notifications) work per body evaluation — `low` [S]
`macos/App/PanelViews.swift:227-243` — one full scan of the 400-element array per device for the outer
filter plus another per device for the inner, recomputed on every `FeedView.body`, producing new array
instances each pass and defeating SwiftUI's identity diffing.

### P-20 · Clicking a banner runs a 500-row query on the main actor before the panel opens — `low` [S]
`macos/App/AppModel.swift:194-201` — on the single most latency-sensitive interaction in the product.

---

# C. macOS interface — visual and layout

<a id="m-01"></a>
### M-01 · No main menu: the app cannot be quit, and ⌘C/⌘V/⌘Q are dead — `critical` [S]
`macos/App/EkoMain.swift:3-13`, `AppDelegate.swift:50-65`, `StatusPanelController.swift:53-62`

`EkoMain.main()` builds `NSApplication.shared`, assigns a delegate and calls `run()` without ever setting
`NSApp.mainMenu`. There is no MainMenu nib, and grepping the whole `macos/` tree for `NSMenu`/`mainMenu`
returns nothing. `NSApp.terminate` appears exactly once — in the startup-failure alert path. The status
item is wired `sendAction(on: [.leftMouseUp])`, so right-click does nothing either.

Consequences for an `LSUIElement` app with no Dock icon:

1. **There is no user-reachable way to quit Eko.** Not from the panel, not from Settings, not from a menu.
   Activity Monitor or `killall`.
2. **A nil `mainMenu` means `NSApplication` has nothing to dispatch key equivalents to.** ⌘Q, ⌘W, ⌘,
   and ⌘C/⌘V/⌘X/⌘A/⌘Z are all inert. That is fatal for the two places the app explicitly opts into text
   interaction: the search field, and the four `.textSelection(.enabled)` sites — a user can select an OTP
   or a device fingerprint and then has **no keyboard way to copy it**.

The pairing dialog's `.keyboardShortcut(.defaultAction/.cancelAction)` still works because SwiftUI routes
those through the window's default/cancel button, which masks the problem during pairing and makes
shortcuts look functional in general.

**Fix:** build an `NSMenu` in `applicationDidFinishLaunching` before `run()` — an app submenu (About Eko,
Settings… ⌘,, Quit Eko ⌘Q) and a standard Edit submenu wired to the responder-chain selectors (`undo:`,
`cut:`, `copy:`, `paste:`, `selectAll:`), which is what makes ⌘C work in text fields under `.accessory`
policy. Separately attach an `NSMenu` to the status item for right-click (Open Eko, Pause banners,
Settings…, Quit), which is the convention every Mac menubar utility follows.

<a id="m-02"></a>
### M-02 · The panel is opaque, so `.ultraThinMaterial` blurs nothing — and traffic lights sit on the logo — `high` [S]
`macos/App/StatusPanelController.swift:23-28,64-80`, `PanelViews.swift:30,39-45`

Two independent defects in the same eight lines, and together they are the most visible "this is an
unfinished port" tells on macOS.

**(a)** `PanelRootView` sets `.background(.ultraThinMaterial)`, which SwiftUI implements as an
`NSVisualEffectView` with behind-window blending. `configurePanel()` never sets `panel.isOpaque = false`
or `panel.backgroundColor = .clear`. A `.titled` NSPanel defaults to `isOpaque == true` with a
`windowBackgroundColor` fill, and behind-window vibrancy cannot sample the desktop through an opaque
window — the material collapses to flat tinted gray. The entire translucency story, the one thing that
makes a menubar popover read as native, is inert. The three hand-rolled translucent layers stacked on top
(`windowBackgroundColor.opacity(0.55)` header, `controlBackgroundColor.opacity(0.35)` search bar,
`controlBackgroundColor.opacity(0.72)` rows) compound it: semi-opaque solid grays composited over a
material is exactly the stack that produces muddy, low-contrast surfaces even when the material *does* work.

**(b)** The style mask is `[.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]`.
`.closable` produces a close button and `.resizable` on a titled window produces a zoom button;
`titlebarAppearsTransparent = true` plus `.fullSizeContentView` pulls content up under the titlebar.
Nothing hides them — `standardWindowButton` appears nowhere in `macos/`. So a red close dot and a green
zoom dot float at the top-left, directly over the 24 pt `BrandMark` and the "Eko" wordmark.

**Fix:** `panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true`, hide all three
standard buttons, and replace the hand-rolled `Color…opacity()` fills with real materials (`.bar` for
chrome, `.regularMaterial` for rows) or real opaque solids — never a translucent solid over a material.

<a id="m-03"></a>
### M-03 · Row actions are hover-gated: unreachable by keyboard/VoiceOver, and they resize the row — `high` [S]
`macos/App/PanelViews.swift:349-374,385-388`

The action bar renders behind `if hovering || notification.otpCode != nil`, where `hovering` comes solely
from `.onHover`. For every non-OTP notification — the majority of the feed — Copy text, Dismiss on phone
and Keep exist only while a mouse pointer is physically inside the row. There is no `@FocusState`, no
`.focusable()`, no `contextMenu` anywhere in `macos/App/`, and the feed is a `LazyVStack` rather than a
`List`, so rows aren't focusable or selectable. A VoiceOver or full-keyboard-access user cannot reach any
per-notification action at all.

Two secondary defects fall out of the same line: (a) the ~20 pt action bar lives inside the row's `VStack`,
so hovering **grows the row and shoves every row below it down** — with no `.animation`, instantaneously —
and because rows below slide under the stationary pointer this cascades into hover flicker while scrolling;
(b) `.accessibilityElement(children: .contain)` combined with `.accessibilityLabel(...)` is a contradictory
pair: `.contain` keeps children individually reachable, so VoiceOver announces the summary and then
re-reads app label, device name, title and body separately.

**Fix:** reserve the action-bar height unconditionally (`.opacity(hovering || isFocused ? 1 : 0)` in a
fixed-height container, or a trailing overlay outside the vertical layout) so the row never changes size.
Add `.focusable()` + `@FocusState` so ↑/↓ moves a selection, plus a `.contextMenu` with the same items.
Use `.accessibilityElement(children: .combine)` and expose actions as `.accessibilityAction(named:)`
entries so they exist regardless of hover.

### M-04 · Filter chips, the degraded strip and gap icons fail contrast in light mode — `medium` [S]
`macos/App/PanelViews.swift:264-270,286-287,409-410`

1. `FilterButton` uses `.foregroundStyle(selected ? .white : .primary)` over
   `.background(selected ? Color.accentColor : ...)`. Against the shipped AccentColor asset
   (sRGB 0.09/0.62/0.64) white text scores ≈3.2:1 — below AA at the `.caption.weight(.semibold)` size used.
   Worse, on macOS `Color.accentColor` resolves to the **user's** System Settings accent unless it's set to
   Multicolor, so a user with the Yellow accent gets white-on-yellow at ≈1.2:1 — completely illegible.
2. The degraded-network strip is `.foregroundStyle(.orange)` on `Color.orange.opacity(0.08)`; system orange
   on a light backdrop is ≈1.7:1. This is the message explaining why discovery silently stopped working —
   the single most important diagnostic string in the panel — rendered essentially invisible.
3. `GapRow`'s suspected-gap icon is `.yellow`, ≈1.3:1 on a light material.

**Fix:** never pair a literal foreground with `Color.accentColor` — use `.selectedMenuItemTextColor`, or
just `.buttonStyle(.borderedProminent)` and let AppKit pick the contrasting label. Define semantic
warning foreground/background pairs that darken in light mode, and verify against
`colorSchemeContrast == .increased`.

### M-05 · Panel header: a fixed 48 pt clamp with a greedy ScrollView fighting a Spacer — `medium` [S]
`macos/App/PanelViews.swift:46-60,84,195-197`

`PanelHeader` puts a horizontal `ScrollView` inside an `HStack` alongside the wordmark, a
`Spacer(minLength: 4)` and three icon buttons, then clamps the whole thing with `.frame(height: 48)`. Two
flexible children split the residual width by SwiftUI's proportional rules, so the device-chip strip gets
an arbitrary width that shifts as the wordmark or button widths change — chips will clip at a boundary
unrelated to how many devices exist. Indicators are disabled and there's no edge fade, so a user with four
phones has chips scrolled out of view with zero indication. The 48 pt clamp (and the search field's
`.frame(height: 30)`) also crops rather than expands when the macOS Accessibility text-size setting grows
the intrinsic height.

**Fix:** give the chip strip `.layoutPriority(1)` and drop the `Spacer`; add a gradient mask so clipped
chips look clipped; replace hard `.frame(height:)` with `.frame(minHeight:)` plus padding.

### M-06 · Connection state is encoded only by an 8 pt monochrome glyph difference — `medium` [S]
`macos/App/PanelViews.swift:98-99,114-121` — `circle.fill` / `circle.dotted` / `circle` /
`exclamationmark.circle` at `size: 8`, below the legibility floor for glyphs on Retina and well below
AppKit's smallest control size, with **no color at any state**. The chip background encodes only
*selection*, not connection. So the panel's primary at-a-glance readout — is my phone connected? — is a
sub-legible shape difference available otherwise only via tooltip. There is also no hover or pressed
feedback, so nothing indicates the chip is clickable.

**Fix:** ~10 pt indicator carrying state in **both** color and shape (green filled / amber pulsing / gray
hollow / red exclamation) so it survives color-blindness and Increase Contrast; a custom `ButtonStyle`
reading `configuration.isPressed`; last-seen in the tooltip.

### M-07 · Settings rows overflow the minimum window width, badly in German — `medium` [S]
`macos/App/SettingsView.swift:18-19,94-135,200-221`

The window is `minWidth: 640` with `.padding(18)` ≈ 604 pt of content. The Devices row puts, in one
non-wrapping HStack: a `.title2` icon; `Text(device.id)` at `.caption2.monospaced()` with **no
`lineLimit`** — and `device.id` is the full 64-hex SHA-256 fingerprint, ~380 pt at that size; the device
name; a connection label whose German `.connecting` value is "Verbindung wird hergestellt" (27 chars); and
*two* buttons. That cannot fit.

`PreferenceRow` is worse: the delivery `Picker` is constrained to `.frame(width: 120)`, and that 120 pt
must hold the picker's *label* **and** its popup button whose widest option is "Ausgeblendet" — guaranteed
truncation of both. Two checkboxes follow ("Codes automatisch kopieren", 26 chars) competing with an
unbounded `Text("\(deviceName) · \(appPackage)")` where package names routinely run 30+ characters.

**Fix:** truncate the device ID to a grouped short form with a Copy button (or move it to a disclosure);
`.lineLimit(1).truncationMode(.middle)` + `.layoutPriority` on leading text; drop the fixed picker width
for `.labelsHidden() + .fixedSize()`. Then re-check both panes forced to `de` at 640 pt.

### M-08 · Status item: wide symbols in a square slot, no highlight, and a badge that never clears — `medium` [S]
`macos/App/StatusPanelController.swift:22,44-51,91-125`

Four defects in the app's most-seen surface. (1) Created with `squareLength` but cycling through symbols
of very different aspect ratios (`iphone.radiowaves.left.and.right` and
`arrow.triangle.2.circlepath.iphone` are markedly wider than tall), with no
`NSImage.SymbolConfiguration` — so wide glyphs render pinched. (2) `togglePanel` never calls
`button.highlight(true/false)`, so the item doesn't appear pressed while its panel is open — the universal
menubar convention, and its absence reads as unfinished. (3) The glyph swaps identity between four
unrelated symbols, so the icon a user learns to aim for changes shape with connectivity. (4) `hasCode` is
`receivedAt > Date() - 60`, but `updateStatusItem` runs only on `objectWillChange`, and the 60 s ticker is
cancelled when the panel hides — so with the panel closed the "a verification code is available" icon
sticks **indefinitely**, long after the code expired.

**Fix:** `.variableLength` + an explicit `SymbolConfiguration`; keep one brand glyph with a state badge
overlay; `button.highlight(panel.isVisible)`; drive the code-available state from a one-shot `Timer`
scheduled at `codeReceivedAt + 60`.

### M-09 · Pairing title centered with a hardcoded 44 pt spacer, and a resampled QR — `low` [S]
`macos/App/PanelViews.swift:448-460,531-554`

The header balances a `Label("Back", systemImage: "chevron.left")` (≈52 pt English, ≈62 pt German) with
`Color.clear.frame(width: 44)`. It matches neither, so the title sits visibly off-center — by ~4 pt in
English, ~9 pt in German — on the app's most important first-run screen. Below it, the QR is upscaled 10×
by the filter (≈700–770 px) and then **down**-scaled into a 220 pt frame with
`.interpolation(.none)` — nearest-neighbour at a non-integer ratio drops whole module rows and columns,
giving uneven module widths and degraded scan reliability on the one screen that must work.

**Fix:** overlay-center the title (or a three-column `Grid`); compute an integer scale factor from the
filter's native module count to the target pixel size and keep `.interpolation(.none)` only for that exact
integer upscale.

---

# D. macOS interface — interaction, states and affordances

### M-10 · Gap rows print raw wire enum tokens — `high` [S]
`macos/App/PanelViews.swift:414`, `SettingsView.swift:241-243`

`GapRow` renders `"\(deviceName) · \(gap.reason)"` where `reason` is the raw protocol evidence code
(`listener_disconnected`, `writer_overflow`, `retention_age`, `peer_cursor_regressed`). So the most
user-facing warning in the product reads *"Telefon könnte Benachrichtigungen verpasst haben ·
writer_overflow"* — an untranslated snake_case machine token, in an app whose selling point includes
complete EN+DE localization (102 keys, all present).

The same leak appears in Settings → Diagnostics, where `StateCard` is fed
`String(describing: model.listenerState)` and friends, rendering Swift enum reflection like
`ready(48808, ...)` as user-visible text, with `.lineLimit(2)` truncation on top.

`GapSpan.startTime`/`endTime` exist on the model and are decoded from the DB but never rendered — "may
have missed notifications" without a time range is not actionable.

**Fix:** a `LocalizedStringResource` mapping per evidence code with a fallback; `displayName` computed
properties on the three state enums; render the interval.

### M-11 · The error strip is permanent — `high` [S]
`macos/App/AppModel.swift:107,190-192`, `PanelViews.swift:17-19,134-147`

`fatalError` is `@Published private(set)` and the only write in the entire app is the assignment in
`setFatalError` — there is no `fatalError = nil` anywhere. `ErrorStrip` has no close button, no retry, and
no auto-expiry. And `setFatalError` is called from genuinely *transient* conditions: a failed
`store.setStarred`, a failed diagnostics export, `beginPairing` before the listener has bound a port, a
transient listener start failure. So starring a notification while the DB is momentarily busy, or clicking
Add phone one second too early after launch, **permanently pins a full-bleed red bar across the panel for
the rest of the process lifetime**. The strip is also `Color.red.opacity(0.88)` with `.white` `.caption`
text — ~3.5:1, below AA, and backdrop-dependent because of the alpha.

**Fix:** distinguish recoverable from fatal. Give the strip an X; auto-dismiss recoverable errors after
~8 s; route non-fatal failures to a transient toast. Replace the alpha red with an opaque semantic error
background.

### M-12 · Definitive gap rows are undeletable and permanently occupy the top of the feed — `high` [S]
`macos/App/PanelViews.swift:159-161`, `EkoStore.swift:1568-1573`

`FeedView` pins `model.gaps.prefix(3)` above every notification with no dismiss, acknowledge or collapse.
On the store side `prune` deliberately protects them — definitive gaps in the current generation are never
deleted, because cursor coverage depends on them. That durability decision is correct; the UI consequence
is a warning banner that is *literally permanent*. After one retention overflow the user's feed carries an
orange "History unavailable" row above every notification, forever, until the generation resets. Three such
gaps consume ~120 pt of a 620 pt panel.

**Fix:** separate storage durability from display. Add `acknowledged_at_ms` (or a UserDefaults set of
acknowledged gap IDs) and a dismiss control; collapse acknowledged gaps into a single "N history gaps
[Show]" chip; sort gaps into chronological position rather than pinning them.

### M-13 · Unpair fires immediately; the *less* destructive Forget is confirmed — `high` [S]
`macos/App/SettingsView.swift:123-152`

`Button("Unpair", role: .destructive) { model.requestUnpair(device) }` sends the unpair the instant it is
clicked — no dialog, no undo, and it revokes trust on the phone over the network. Immediately adjacent,
`Forget…` — which only forgets a device that is *already* revoked — gets a full `confirmationDialog` with
an explanatory message. So the app guards the recoverable action and leaves the irreversible one one click
away, rendering both as identical small destructive buttons in the same row. Recovery requires the full
9-step pairing flow on the phone.

**Fix:** put Unpair behind a `confirmationDialog` stating the phone must re-pair from scratch, and move
`Forget…` into a per-row menu so only one primary destructive affordance is exposed at a time.

### M-14 · `PreferenceRow` copies its model into `@State` at init, so it goes stale — `high` [S]
`macos/App/SettingsView.swift:180-182,191-224`

```swift
@State private var preference: AppPreference
init(preference: AppPreference, ...) { _preference = State(initialValue: preference) ... }
```

SwiftUI honours `State(initialValue:)` only the *first* time a view of a given identity is created; on
every subsequent update the initializer runs but the stored `@State` is kept. The parent is
`List(model.appPreferences)` driven by a live `store.observeAppPreferences()` stream. So any preference
change not originating from this row — a new device's default, another code path, or this row's own
round-trip echo — is silently discarded and the row keeps rendering its stale copy. Meanwhile
`.onChange(of: preference)` writes to the store on every mutation, making the row a **write-only surface
whose displayed state can permanently diverge from what is persisted**.

**Fix:** drop the `@State` mirror; bind each control through an explicit `Binding` reading the incoming
value and writing via `onChange`, so the store stays the single source of truth.

### M-15 · Pairing has no manual fallback: the token is captured but never shown — `high` [S]
`macos/App/AppModel.swift:214-227`, `PanelViews.swift:475-481`

`beginPairing` builds `PairingDisplay` with host, port, fingerprint **and** `invitation.token`.
`PairingView` renders Address, a 16-character fingerprint prefix and an expiry countdown; `display.token`
is never rendered anywhere in `macos/`. PLAN's pairing design specifies QR *plus* a manual line precisely
so pairing survives a broken camera, poor lighting, or a phone that can't scan. As shipped there is **no
fallback path at all**. The fingerprint is also truncated with an ellipsis and is not
`.textSelection(.enabled)` (unlike the device ID in Settings), so a security-conscious user cannot copy it
to compare, and there is no "Copy pairing link".

**Fix:** render the full manual line (host:port, full fingerprint, token) in a selectable monospace block
with a Copy button, and make fingerprint presentation consistent across the three sites that show one.

### M-16 · Banner authorization is provisional-only, and nothing surfaces or repairs it — `high` [S]
`macos/Sources/EkoCore/NotificationCoordinator.swift:43-46,105`

`configure()` requests `[.alert, .badge, .provisional]` and discards the result. Provisional authorization
deliberately grants **quiet** delivery — notifications land in Notification Center without a banner — until
the user explicitly promotes the app. Since native banners with a Copy code action are the product's
headline feature, the default first-run experience is that *nothing visibly happens when a code arrives*.

Nothing detects this: `UNAuthorizationStatus` is never read, the Notifications settings pane shows only a
global pause toggle, and the Diagnostics state cards cover listener/Bonjour/Bluetooth but not notification
authorization. There is also no `willPresent` implementation, so even after promotion banners are
suppressed whenever Eko is frontmost — which is exactly the state `showPanel()` forces via
`NSApp.activate(ignoringOtherApps: true)`.

**Fix:** read `getNotificationSettings()` on launch and after `configure()`; if `.provisional` or
`.denied`, show an inline panel row and a Notifications-settings card with a deep link (mirroring the
existing `openLocalNetworkSettings()` pattern). Implement `willPresent` returning `[.banner, .list]`.

### M-17 · Empty state shows the wrong message when a filter returns nothing — `medium` [S]
`macos/App/PanelViews.swift:163-166,426-439` — `EmptyFeedView` branches only on `hasDevices`, but
`model.notifications` is a *filtered* query result. Typing a query with no matches, selecting a quiet
device chip, or enabling Codes when no codes exist all render "No notifications / New notifications from
your phones appear here" — which tells the user their phones have sent nothing. That is false and actively
misleading, and it offers no escape from the filter that produced it. Layout-wise it sits inside the
`LazyVStack` with `.padding(.top, 56)`, so a `ContentUnavailableView` designed to center itself ends up
top-anchored under a magic pad.

**Fix:** three cases — no devices → pair CTA; devices + active filter → "No results for '…'" with a Clear
filters button; otherwise the current copy. Move it into an `.overlay` on the ScrollView so it centers.

### M-18 · Star / Keep has no visible effect anywhere — `medium` [S]
`macos/App/PanelViews.swift:199-220,359-368`, `EkoStore.swift:1701-1743`

`isStarred` is consumed nowhere except the button's own label, so a starred notification is visually
identical to an unstarred one. There is no way to *see* starred items: the filter row offers only All and
Codes, and `fetchNotifications` neither filters nor orders on `is_starred`. The only real consequence of
starring is invisible — `prune` exempts starred rows. Users are invited to curate a collection they can
never look at, and can only discover an item's starred state by hovering it.

**Fix:** a filled star in the row metadata when starred; a third filter chip ("Kept") backed by
`starredOnly` on `FeedQuery`; state in the tooltip that kept items survive pruning — that is the actual
value proposition and it is currently hidden.

### M-19 · The panel floats at `.popUpMenu`, above the Settings window it opens — `medium` [S]
`macos/App/StatusPanelController.swift:70,141-145,158-163` — `.popUpMenu` is above `.floating`, above
`.modalPanel`, above normal windows and system alerts. `windowDidResignKey` deliberately keeps the panel on
screen when Settings takes key, and AppKit's resignKey/becomeKey ordering is not guaranteed, so the
420×620 panel can remain floating above the Settings window the user just opened. It is also above the
`NSAlert(error:)` raised on startup failure.

**Fix:** `.floating` (or `.statusBar`), which is the conventional level for a menubar popover, and
explicitly `orderOut` the panel when opening Settings.

### M-20 · Copy actions give no feedback at all — `medium` [S]
`macos/App/AppModel.swift:250-257`, `PanelViews.swift:330-336` — no checkmark, no label swap, no flash, no
sound, no VoiceOver announcement. For an app whose central interaction is "a code arrived — copy it", the
primary action produces zero perceptible response; the only way to confirm success is to switch apps and
paste. Compounded by auto-clear: the code silently vanishes from the pasteboard after two minutes with no
indication that it happened or is about to.

### M-21 · Diagnostics log rows are keyed by timestamp, can't wrap, and never auto-refresh — `low` [S]
`macos/App/SettingsView.swift:249-262` — `List(..., id: \.timestamp)` will produce duplicate identities
(the recorder emits bursts from session state changes and ingest), which in SwiftUI causes runtime warnings
and rows that fail to update. Messages sit in an `HStack` with a trailing `Spacer` and no `lineLimit`, so
long lines are clipped horizontally with no wrap and no way to read the tail — `.textSelection(.enabled)`
doesn't help when the text is clipped. The list refreshes only on `.onAppear` or an explicit click, so a
user watching Diagnostics while reproducing a problem sees a frozen log.

**Fix:** a stable UUID on `DiagnosticEvent`; let messages wrap
(`.fixedSize(horizontal: false, vertical: true)`, drop the `Spacer`); add live-tail and Copy-all.

### M-22 · No About window, no version display, no Help, no update path — `low` [S]
`CFBundleShortVersionString` is read exactly once in the whole app — to stamp the diagnostics export. A
user who wants to know which build they're running, or a maintainer triaging a report, cannot find the
version anywhere in the UI. With no main menu there's also no standard About item and no Help. And since
distribution is Developer-ID/sideload-only by design, the absence of any updater means there is no
mechanism at all to deliver a fix to an installed copy.

---

# E. Android interface

<a id="a-01"></a>
### A-01 · Every cold launch lands on the setup checklist — `high` [S]
`android/app/.../EkoScreens.kt:117-121`

`var page by remember { mutableStateOf(AppPage.SETUP) }` hard-codes the start destination. The only escape
is `LaunchedEffect(...) { if (confirmedPeers.isNotEmpty() && pairing is PairingUiState.Success) page = HOME }`,
and `pairing` is a fresh `Idle` on every cold process. So a fully-paired, fully-permissioned user opens the
app — or taps the persistent foreground-service notification — and lands on an eight-card permission wall
titled "Set up Eko", not on their Macs. There is no way to dismiss or collapse setup once complete.

**This single line is the biggest reason the app reads as "a wall of buttons" rather than a product.**

The same `LaunchedEffect` also reads `pairing` without keying on it (a stale read that happens to work),
and when it fires it yanks the user off the checklist the instant pairing succeeds — abandoning the
remaining ungranted steps mid-flow with no explanation.

**Fix:** derive the start destination from state — HOME when
`confirmedPeers.isNotEmpty() && checks.notificationAccess`, SETUP only while setup is genuinely
incomplete — and persist the last tab in `rememberSaveable`. On pairing success, advance the checklist in
place rather than navigating away.

### A-02 · QR scanner has no back handling, no insets, and an **invisible** reticle — `high` [S]
`android/app/.../MainActivity.kt:76-96`, `ui/QrScanner.kt:94-107`

- The scanner is not a destination: `if (scannerVisible) { QrScanner(...); return }` swaps out the entire
  UI tree. There is **no `BackHandler` anywhere in the app module**, so pressing Back while scanning
  **exits the app**. With `targetSdk = 36` predictive back is on, so the user gets a full app-dismiss
  preview animation while pointing the camera at their Mac.
- The framing reticle paints transparent over transparent:
  `Box(Modifier.align(Center).size(260.dp).background(Color.Transparent, RoundedCornerShape(24.dp)))`.
  The user gets a bare full-bleed camera feed with **no aiming guide at all**. The intent is obvious from
  the code; the result renders nothing.
- No inset handling: the bottom `Column` uses a flat `24.dp` padding outside any `Scaffold`, so on a 48 dp
  three-button nav bar the "Close scanner" button sits under system chrome.
- The copy is wrong for the context: it reuses `R.string.pair_body` = "Scan the QR code from Eko on your
  Mac, choose a discovered Mac, or enter its address" — instructing the user, from inside the viewfinder,
  to instead pick a discovered Mac or type an address.

**Fix:** `BackHandler { onClose() }`; a real reticle (rounded-rect stroke plus a dimmed scrim outside it,
success pulse on detect); `.systemBarsPadding()`; a dedicated instruction string; a torch toggle; an
"Enter details manually" secondary action.

### A-03 · Permission denials produce silently dead buttons — `high` [S]
`android/app/.../MainActivity.kt:72-74,102-106,135-137`

Camera: `RequestPermission()) { granted -> scannerVisible = granted }`. If the user denies, **nothing at
all happens** — no message, no rationale, no route to Settings. After the second denial Android stops
showing the system dialog, so "Scan QR code" becomes a button that visibly does nothing, forever, with no
way back. POST_NOTIFICATIONS is the same shape.

Neither path calls `shouldShowRequestPermissionRationale`, and there is **no `Snackbar`/`SnackbarHost`
anywhere in the app module**, so there is no channel for transient feedback at all. Returning from a
Settings deep link refreshes state correctly, but if the user comes back without granting, the card is
byte-identical to before — no "still not enabled, here's the toggle you're looking for".

**Fix:** model three states per permission (not-asked / denied-once / permanently-denied) with distinct
copy and an "Open app settings" fallback for the third; track a `requestedAt` and, when `onResume` fires
soon after a request with the check still false, show an inline hint naming the exact Settings toggle.

### A-04 · German status text starves the Mac name to one character per line — `high` [S]
`android/app/.../EkoScreens.kt:522-527,539-548`

In the peer card header the Mac name is the only weighted child, sitting next to an unconstrained
`TransportStatus` chip whose label has no `maxLines`. Compose measures the unweighted `AssistChip` first
against the full remaining width, so it claims its full intrinsic single-line width and the name gets the
scraps. On a 360 dp phone the row has ≈296 dp; `status_waiting_network` ("Warten auf WLAN, Ethernet oder
VPN") renders ≈230 dp of text plus icon and chip padding ≈280 dp, leaving under 30 dp for a 22 sp name —
i.e. it wraps to one glyph per line. `status_syncing` DE is longer still, and `status_failed` interpolates
an arbitrary-length exception reason into the same chip.

**This is the single most visible layout break in the app, and it hits the Home screen.**

**Fix:** chip on its own line below the name (or a trailing `Column`); `maxLines = 1` + ellipsis on both;
truncate `Failed.reason` to a short localized cause.

### A-05 · Checklist state is conveyed by color and a null-described icon only — `high` [S]
`android/app/.../EkoScreens.kt:257,266,385-409,439-456`

`ChecklistCard` signals done/blocked/informational through a container tint plus an
`Icon(..., contentDescription = null)`. The `status` string is optional and several cards omit it — the
pairing card and the managed-profile card pass none at all. For a TalkBack user the pairing card therefore
reads identically whether or not pairing has already succeeded: there is **no way to hear which steps are
complete**. It is also a plain WCAG 1.4.1 (use of color) failure for sighted users with colour-vision
deficiency.

The affordances contradict the state too: the notification-access card always renders "Open notification
access" and the CDM card always renders "Associate Mac over Bluetooth" even when satisfied, while the POST
and battery cards correctly hide their buttons when healthy. So a finished checklist still looks like
unfinished work. There is no progress indicator of any kind in the app.

**Fix:** make `status` non-optional and always populated; give the icon a real description, or better,
`Modifier.semantics(mergeDescendants = true) { stateDescription = … }` on the card; collapse completed
cards to a single-line row and hide their buttons; add a "5 of 8 complete" header.

### A-06 · Switch rows are two separate a11y nodes with an unlabelled control — `medium` [S]
`android/app/.../EkoScreens.kt:512-515,581-586` — `RuleSwitch` is `Row { Text(label, weight(1f)); Switch(...) }`
with no `Modifier.toggleable(role = Role.Switch)` on the row. TalkBack focuses the text, then separately
focuses a switch announced only as "on, switch" with no name, and tapping the label — the natural target,
the whole row width — does nothing. On the Apps screen that is three unlabelled switches per app card. The
Home master toggle is worse: it announces as a bare "on, switch" while its descriptive text sits in a
separate `Column`.

**Fix:** the standard pattern —
`Row(Modifier.toggleable(value, onValueChange, role = Role.Switch).minimumInteractiveComponentSize()) { Text(label, Modifier.weight(1f)); Switch(checked, onCheckedChange = null) }`.

<a id="a-07"></a>
### A-07 · Force-stop silently pauses forwarding with no in-app explanation — `medium` [S]
`android/app/.../EkoApplication.kt:60,76`, `EkoViewModel.kt:41-48`

After a `REASON_USER_REQUESTED` exit the product is off. The only clearing path is the master `Switch` on
the Home tab. But the app opens on Setup, every checklist card still reads green, and `SystemChecks` does
not include `forwardingPaused` at all — so the setup screen has no idea the product is disabled. Nothing
anywhere says "Eko was force-stopped, so forwarding was paused — turn it back on." The behavior is
defensible; the total absence of explanation is not. (See also [B-10](#b-10), which is why this fires far
more often than intended.)

**Fix:** add `forwardingPaused` + `pausedReason` to `SystemChecks` and render a prominent, dismissible
banner at the top of *every* screen with a one-tap Resume.

### A-08 · Diagnostics leaks raw internals — `medium` [S]
`android/app/.../EkoScreens.kt:631-661`, `TransportRuntime.kt:43`

The screen meant to be reassuring prints developer artifacts: untranslated Kotlin class names
(`state::class.simpleName` — "WaitingForNetwork", "Reconnecting" — even though localized equivalents
already exist in `strings.xml` and are used by `TransportStatus`); raw epoch millis, because
`TransportRuntime.log` prefixes every line with `"${System.currentTimeMillis()}: "`; a numeric
`ApplicationExitInfo` constant rendered as "Recent process exit reason: 10"; raw `presence.event` and
association IDs. All 100 retained log lines are rendered eagerly inside one `LazyColumn` item, so none of
them are lazily composed. Meanwhile `CaptureHealth.lastTransition`, `commitFailures` and
`reconciliationFailures` are collected and never rendered, though PLAN lists NLS bind transitions as a
requirement.

### A-09 · Relative timestamps freeze exactly when the listener is dead — `medium` [S]
`android/app/.../EkoScreens.kt:617-618,654,678-682` — `relativeTime` computes
`System.currentTimeMillis()` inside composition, which is not snapshot state, so it only recomputes when
its `wall` argument changes. The failure is precisely inverted from what a diagnostics screen needs: while
the listener is healthy `CaptureHealth` emits often and the value looks live; **the moment the listener
dies — the one situation the screen exists to diagnose — nothing emits and the screen keeps insisting the
last callback was "3 minutes ago" indefinitely.**

**Fix:** a ticking `produceState` clock passed in, plus a severity color once the age crosses a threshold.

### A-10 · Unpair dialog crams three buttons into two slots and styles the destructive action as primary — `medium` [S]
`android/app/.../EkoScreens.kt:479-500` — a `Row { TextButton("Forget without notifying"); TextButton("Cancel") }`
goes into the single `dismissButton` slot. M3's `AlertDialogFlowRow` can wrap *between* slots but not
*inside* one, so that Row is atomic; three labels cannot fit ~312 dp, and the German
"Ohne Benachrichtigung vergessen" (30 chars) is longer. The hierarchy is also wrong: `unpair_body` says
local history and cursors are deleted immediately — irreversible — yet "Unpair" is the filled primary
`Button` while "Cancel" is a tertiary `TextButton` buried in a nested Row. The eye-catching,
thumb-adjacent affordance is the one that destroys data.

**Fix:** three stacked full-width actions — "Unpair" (error-coloured), "Forget without notifying"
(outlined, with a one-line explanation of the difference, which nothing currently gives), "Cancel" (text).
Vertical stacking also removes the German overflow.

### A-11 · Dark-mode cold start flashes mid-grey — `medium` [S]
`android/app/src/main/res/values-night/styles.xml:2`, `ui/EkoTheme.kt:31`

`Theme.Eko` inherits the **platform** `android:style/Theme.Material.NoActionBar`, whose night
`windowBackground` is `#FF303030`. The Compose surface underneath is `#FF101513` — near-black. Every cold
launch paints a full-screen mid-grey window then snaps to near-black. No `android:windowBackground` is
declared in either styles file and the app doesn't use `androidx.core.splashscreen`. (The light pair,
`#FAFAFA` vs `#F7F9F7`, is close enough to be invisible — which makes this easy to miss in review and very
visible to users.)

### A-12 · Foreground-service notification has no deep link — `medium` [S]
`android/transport/.../ConnectionService.kt:214-217`, `MainActivity.kt:37-47` — the content intent is a bare
`getLaunchIntentForPackage` with no extras, and `MainActivity` has no `onNewIntent` and no intent parsing.
So the notification saying "Reconnecting to paired Macs" drops the user on the Setup checklist rather than
Home or Diagnostics. The text is also state-blind about *which* Mac ("Connected to %1$d Mac(s)" even in the
overwhelmingly common one-Mac case) and uses a parenthetical plural rather than a `<plurals>` resource —
which the app already does correctly for `queued_events`.

### A-13 · The Apps screen is the raw-toggle wall the product is trying not to be — `medium` [S]
`android/app/.../EkoScreens.kt:559-578`

One card per `(package, user)` with three bare switches each. On a typical phone that is 100–200 cards and
300–600 switches in one flat `LazyColumn`, with: no search or filter; **no app icons** (trivially available
from `PackageManager`, and the single highest-impact visual upgrade here); no grouping beyond alphabetical,
so forwarded and muted apps interleave; no use of `lastSeenWall`, which is already in the row; no
explanation of what "Contains codes" does even though it changes OTP extraction behavior on the Mac; no
bulk actions.

Also, `apps` starts as `emptyList()` from `stateIn`, so opening the tab **flashes the empty state** to users
who are not empty. Home has the identical flash — a paired user briefly sees "No Macs are paired yet."

**Fix:** sticky search + segmented filter; icons behind a small LRU cache at 40 dp; collapse the two
secondary switches behind a per-row expander so the default row is `[icon] Label —— [Forward]`; a nullable
initial value so loading and empty are distinguishable.

### A-14 · Adaptive icon is off-center and has no monochrome layer — `low` **[V]**
`android/app/src/main/res/drawable/ic_launcher_foreground.xml`, `mipmap-anydpi-v26/ic_launcher.xml`

The glyph occupies x ∈ [25, 74], y ∈ [22, 76] of a 108×108 viewport — a visual center of (49.5, 49) instead
of the required (54, 54) — so under circular and squircle masks it reads as shifted up and left. The
adaptive icon declares only `<background>` and `<foreground>`; with **no `<monochrome>` layer**, Eko will be
one of the few icons on an Android 13+ home screen that refuses to tint. `mipmap-anydpi/` (unversioned) is
also unreachable given `minSdk = 26` — **lint confirms this**: *"This folder configuration (v26) is
unnecessary; minSdkVersion is 26."*

The Android launcher glyph is also an entirely different mark from the macOS `BrandMark` (a generic
"phone with lines" vs. the wave-and-phone logo), and the Android theme seed is `#075E54` while the macOS
brand gradient is `#22C6B7 → #13759F` and the AccentColor asset is teal `rgb(0.09, 0.62, 0.64)`. **The two
halves of one product do not share a brand.**

### A-15 · Small affordance problems that read as unfinished — `low` [S]
- `TransportStatus` is `AssistChip(onClick = {})` — M3 wraps it in a clickable `Surface` with `Role.Button`,
  so TalkBack announces an actionable button whose double-tap does nothing. It should be a badge.
- Pending pairings render as unlabelled bare `TextButton`s with no expiry, no endpoint and **no way to
  dismiss one**. Stale entries clear only via `HealthWorker`'s 15-minute `pruneExpiredPending()`.
- The top-bar `+` implies a modal add-device flow but merely sets `page = SETUP` — identical to the Setup
  tab two inches below.
- The SAS verify dialog is owned by `OnboardingScreen`, not hoisted to the root, so changing tabs
  mid-verification makes the security-critical code disappear while the handle keeps ticking toward expiry.

---

# F. Security & privacy

<a id="s-01"></a>
### S-01 · Unbounded inbound frame queue, reachable pre-confirmation — `high` [S]
`macos/Sources/EkoCore/NetworkTransport.swift:132,162,174,221`

`receiveNext()` always re-arms, decodes every complete frame, and appends into an uncapped
`[WireMessage]`. Frames are capped at 1 MiB each; the *number* of buffered frames is not. The session
layer is a serial actor with long pauses where it consumes nothing — most importantly
`runPairing` blocking on `await pairingApproval(pending)` for up to the 5-minute attempt expiry while the
user decides. Nothing is read during that window, but the reader keeps parsing and enqueuing.

That window is reachable by any peer pairing mode admitted — i.e. **before any user confirmation**. A LAN
host can grow the Mac's memory until it is OOM-killed.

**Fix:** cap both queued count and cumulative bytes (e.g. 64 messages / 4 MiB) and either apply real
backpressure (stop re-arming above a high-water mark) or treat overflow as a protocol violation and cancel
the connection. Also cap concurrent pairing-window connections.

### S-02 · The pairing admission fingerprint is latched inside the TLS verify block — `medium` [S]
`macos/Sources/EkoCore/TLSListener.swift:129`, `PeerAdmission.swift:58-67`

`sec_protocol_options_set_verify_block` runs `authorizer.authorize(certificateDER:)` *during* the TLS
handshake, and for an unknown certificate that reaches `admitUnknown`, which is **not a pure predicate** —
it mutates state: `current.admittedFingerprint = fingerprint`. From then on every *other* unknown
certificate is rejected for the rest of the window. So the first LAN host to present any self-signed leaf
during the pairing window claims the single TOFU slot — before any QR scan, any SAS, any user action —
and the legitimate phone cannot pair until the window is restarted.

This is a denial-of-pairing, not a trust bypass (the SAS still protects confidentiality), but it is
trivially triggerable by anything on the network.

**Fix:** make `authorize()` side-effect free during certificate verification; latch the fingerprint after
the handshake completes, or better, when the peer's `hello` is accepted. Release the latch when the attempt
fails so a bad first connection doesn't poison the window.

### S-03 · Banking/TAN exclusion inspects only the body — `medium` [S]
`macos/Sources/EkoCore/NotificationCoordinator.swift:110,192`

PLAN promises OTP auto-copy is "never for banking/TAN messages". The gate is a single regex over
`outcome.body`, which is `bigText → text → last message → textLines → subText/infoText/summaryText`. It
never includes the notification **title** and never considers the **app identity**. A message whose title
is "Zahlung freigeben" and whose body is "Code: 481920" passes the filter and gets auto-copied.

**Fix:** run `isBankingStyle` over title + app label + body together, and add a package-based deny path
(finance-category apps, or an explicit per-app "treat as sensitive" flag). Auto-copy already requires an
explicit per-app opt-in, so failing closed costs little. (Also: the regex is recompiled on every call via
`range(of:options:.regularExpression)` — hoist it to a `static let NSRegularExpression`.)

### S-04 · Copied OTP codes go to `NSPasteboard.general` and can sync via Universal Clipboard — `medium` [S]
`macos/Sources/EkoCore/ClipboardController.swift:14-28`, `docs/privacy-and-data-handling.md:80`

`org.nspasteboard.ConcealedType` is a community convention honoured only by cooperating third-party
clipboard managers; it is not an Apple mechanism and does not mark the item local-only. The general
pasteboard is the one Handoff/Universal Clipboard replicates to every iPhone, iPad and Mac on the same
iCloud account within range, with no user action. For a product whose entire premise is keeping OTPs on
your own paired devices, that deserves an explicit decision and an explicit sentence in the docs.

**Fix:** verify the behaviour on a current macOS build; if it does replicate, either use a non-general
pasteboard plus an explicit paste affordance or apply whatever local-only marking the platform supports. At
minimum document it next to the auto-copy opt-in.

### S-05 · Bonjour advertises a permanent identity fingerprint on every network, always — `medium` [S]
`macos/Sources/EkoCore/BonjourPublisher.swift:31-42`, `AppDelegate.swift:22-30,184`

The TXT record is `["fp": <64-hex certificate fingerprint>, "proto": "1"]` under the service name
`"Eko on <computer name>"`. That fingerprint is the Mac's **permanent** device identity — the certificate
is minted with 20-year validity and never rotates. Publication is unconditional and re-armed on every
network change, with no off switch. Join a café or conference Wi-Fi and Eko broadcasts a stable, globally
unique tracking identifier plus your computer's name to everyone on the segment.

**Fix:** publish `fp` only while pairing mode is active; outside that window either omit it (paired phones
confirm identity at TLS anyway, which is already the design) or publish a short per-network rotating tag.
Add an "Advertise on the local network" toggle and gate BLE the same way. Update
`docs/privacy-and-data-handling.md` to say precisely what is broadcast and when.

### S-06 · The "include notification content" diagnostics toggle isn't one-shot — `low` [S]
`docs/security-model.md:140` states "Enabling content applies to one export, not future exports."
`exportDiagnostics()` never resets `includeContentInDiagnostics`, so it stays on for the remainder of the
session. One line at the end of the export (on both paths) makes the implementation match the promise.

### S-07 · macOS diagnostics export ignores the documented redaction contract — `high` [S]
`macos/Sources/EkoCore/DiagnosticsRecorder.swift:72-103`, `docs/diagnostics.md:57-84`

The docs define a **mandatory** redaction table for the default content-off export: notification key →
per-export salted digest, app package/label → digest, device/user names → `phone-1`/`mac-1`, certificate
fingerprint / device ID → short prefix or digest, IP address/hostname → removed, and explicitly "a default
export must transform sensitive values before writing the archive, not merely hide them in the UI". The
shipped exporter honours exactly **one** of those rows (title/body dropped). Everything else — device IDs,
device names, fingerprints, addresses — is written verbatim. A user following the support instructions
attaches all of it to a public issue.

**Fix:** a `DiagnosticsRedactor` with a per-export random salt (never written into the payload): HMAC the
keys and packages, replace device IDs/names with stable ordinals, drop `pinnedCertificateDER` and
`lastIPAddress`, truncate the identity fingerprint.

### S-08 · `UdpHintListener` accumulates attacker-controlled entries without bound or expiry — `low` [S]
`android/pairing/.../UdpHintListener.kt:55-63` — rate-limiting and the 42-peer cap apply to *source hosts*,
but the published hint list has neither cap nor expiry, and dedup is keyed on `fingerprint`, which is
entirely attacker-chosen. One LAN host emitting a packet every 500 ms with a fresh random fingerprint adds
a permanent entry each time, each carrying an attacker-chosen name of up to 128 chars — an unbounded list
of spoofed "Macs" in the pairing UI.

**Fix:** cap the list (~16, evicting oldest), expire after ~60 s of silence, dedup by source IP, and mark
UDP/mDNS-sourced chips as *unverified* in the UI so it is visually clear only the QR path carries an
authenticated fingerprint.

---

# G. Missing features and product gaps

### F-01 · Promised in PLAN/docs but not implemented — `high`

| Promise | Where promised | Status |
| --- | --- | --- |
| Global keyboard shortcut for panel / latest code (⌃⇧⌘V, opt-in, collision warning) | PLAN:1218-1221 | No hotkey registration anywhere |
| Per-device banner pause + macOS Focus auto-pause | PLAN:1198-1200 | `allowsBanner(deviceID:)` seam exists; the only impl ignores the parameter |
| Android onboarding step 9: send test notification, round-trip proof | PLAN:1256, `docs/install-and-pair.md:96` | Absent; checklist stops at step 8 |
| Per-device retention in the Devices pane | PLAN:1213-1214 | Two global steppers in *General*; Android's per-pairing columns exist but no caller sets them |
| Inline backlog banner ("N missed … [Show]") | PLAN:1179-1181 | Surfaced as a system notification instead — a banner about banners |
| "Mute this app" as a row action | PLAN:1193-1194 | Store side fully implemented; reachable only via Settings |
| "Identity changed — re-pair required" guided flow | `docs/install-and-pair.md:130` | Neither side implements it; the Mac just fails the handshake silently |
| Android diagnostics export | `docs/diagnostics.md:13-37` | Does not exist; the transport log is in-memory only and dies with the process |
| macOS diagnostics redaction table | `docs/diagnostics.md:57-84` | See [S-07](#s-07) |
| Delete-history control | `docs/privacy-and-data-handling.md:93`, `install-and-pair.md:148` | No such control; bulk deletion is private and reachable only via unpair |
| Update notice ("new version available" + link) | PLAN:467-468 | Neither app can tell the user a new version exists |
| macOS notification-authorization upgrade prompt | PLAN:614-615 | Provisional only, result discarded, no state display — see [M-16](#m-16) |

### F-02 · The Mac cannot say "notification access is off on the phone" — `high` [S]
PLAN:1206-1208 lists this as a first-class degraded panel state. The wire protocol carries **no phone-health
signal at all**: `hello` has device id/name/os/caps/generation/epoch/time and nothing about listener bind
state, notification-access grant, redaction self-check or forwarding-paused. `ConnectionService` connects and
heartbeats whenever a confirmed peer exists, independent of whether the listener is bound. So a phone whose
notification access was revoked — a routine consequence of an Android update or restricted settings — shows
as a **green, connected chip that silently delivers nothing**. That is the worst possible failure mode for
this product: it looks like it is working.

**Fix:** an optional `health` object on `hello` and on the phone→Mac `ping` carrying `listener_bound`,
`notification_access`, `forwarding_paused`, `redaction_detected`, `outbox_depth`; must-ignore on older peers.
Store it on the device row; render a degraded strip and an amber chip. (Note this needs `ext_types` to
actually negotiate — see [B-23](#b-23).)

### F-03 · Starring is fully plumbed with no way to view starred items — `medium`
See [M-18](#m-18). `FeedQuery` needs `starredOnly`, `fetchNotifications` needs the predicate, the filter row
needs a third chip.

### F-04 · History is only 400 rows deep, and muted apps vanish from it entirely — `medium` [S]
`macos/App/AppModel.swift:410-415`, `EkoStore.swift:1717` — the panel observes one fixed `limit: 400` query
(clamped to 500 in the store) with no pagination, no infinite scroll, no date jump and no "show older",
while retention defaults to 7 days / 5 000 per device and is configurable to 90 days / 50 000. So 90 % of the
history the user is paying disk for is unreachable except through free-text search — and the retention
steppers imply the opposite. Separately, the feed unconditionally filters `banner_mode != 'muted'`, so muting
an app for *banners* also erases it from *history*, which is not what "mute" means anywhere else.

**Fix:** cursor pagination (`beforeReceivedAt`) plus a "Load older" row; split the mute semantics — keep
muted out of banners, and either keep its rows dimmed in the feed or add a "Show muted apps" toggle.

### F-05 · Per-app rules only exist for apps that already notified — `medium` [S]
Both sides derive the app list from traffic (`seen_app` on Android, `app_preference` on the Mac). So there is
no way to pre-mute a noisy app before it is noisy, no curated defaults, and both screens start empty. PLAN
promises "default: all except ongoing/media" as a policy, which implies a seedable list.

**Fix:** seed the Android Apps screen from `PackageManager` (launcher-intent packages), add a small curated
deny-list of noisy system packages as first-run defaults, and let the Mac add a rule for any app seen on any
device.

### F-06 · Phones are indistinguishable and unrenameable — `medium` [S]
The name comes from the build (`Build.MODEL` at pairing, `"$MANUFACTURER $MODEL"` afterwards — already an
inconsistency, see [B-26](#b-26)), neither side offers a rename, and even if it did the Mac overwrites `name`
from `hello.deviceName` on every connection. For the product's stated multi-phone premise, a household with
two of the same model gets two identical chips.

**Fix:** a `display_name` column set by the user on the Mac that takes precedence over a separately-tracked
`reported_name`, with an inline rename in the Devices pane.

### F-07 · Not promised, but the first three things a switcher reaches for — `low`
Inline reply (KDE Connect and Phone Link both do it via `RemoteInput`; PLAN defers it with fields reserved),
app icons in the feed (every row is a text label, which makes a 400-row list hard to scan; deferred to the
reserved binary frame type), and shared clipboard / send-file / ring-my-phone. Keeping the deferral is right;
making it *visible* ("Reply is coming in 1.x" where the affordance would sit) costs nothing. Of the three,
app icons are the cheapest large perceived-quality win and worth pulling into the first point release.

---

# H. Build, CI, tests, docs

> **Re-baselined.** This review was written against `56b6796`. While it was being written,
> `2bf40dd` (PR #4, "Land the CI/CD the blueprint described") landed on `main` and resolved
> several items in this section outright: `.github/workflows/ci.yml` and `release.yml` now
> exist, `scripts/check-protocol.py` validates every schema and embedded scenario frame,
> Dependabot covers Gradle and Swift, and README/AGENTS no longer claim pre-scaffold status.
> The entries below are what survives against that newer `main`. Nothing was deleted —
> C-01, C-07 and most of C-08 are recorded as resolved rather than dropped.

### C-01 · ~~No CI at all~~ — **resolved on `main` by #4**
`ci.yml` now runs four jobs (protocol, tools, android, macos) on every push and PR, and
`release.yml` re-proves a tagged commit through `workflow_call`. Kept here only as the
provenance for C-03, which is a defect *in* that new workflow.

**Verified here:** with a real SDK 36 + JDK 17 toolchain, `./gradlew :app:assembleDebug test lint` completes
green from a clean checkout — so the Android job's premise holds.

### C-02 · `:core`'s JDK-17 toolchain breaks the build on any other JDK — `high` **[V]**
`android/core/build.gradle.kts:6`, `android/settings.gradle.kts:1`

`:core` declares `kotlin { jvmToolchain(17) }`. The other five modules use
`compileOptions`/`kotlinOptions.jvmTarget` and compile with whatever JDK Gradle runs on. `settings.gradle.kts`
configures no toolchain resolver (`foojay-resolver-convention`), so Gradle can neither find nor download a
JDK 17.

**Reproduced verbatim in this container** (JDK 21 only — the same situation as `ubuntu-latest` when
`setup-java` picks 21):

```
> Could not resolve project :core.
   > Failed to calculate the value of task ':core:compileJava' property 'javaCompiler'.
      > Cannot find a Java installation on your machine (Linux 6.18.5 amd64) matching:
        {languageVersion=17, vendor=any vendor, implementation=vendor-specific}.
        Toolchain download repositories have not been configured.
```

Installing Temurin 17 and setting `JAVA_HOME` fixed it. **Fix:** pick one policy — either drop
`jvmToolchain(17)` so `:core` matches the other five and builds on any JDK ≥ 17, or add the foojay resolver
and apply the toolchain uniformly. Either way CI must pin the JDK explicitly.

### C-03 · The shipped CI command silently skips every `:core` test — `high` **[V]**
`ci.yml`'s Android job — and `CICD.md` and `AGENTS.md`, which document the same command —
run `./gradlew testDebugUnitTest lintDebug assembleDebug`. `:core` applies
`org.jetbrains.kotlin.jvm`, not `com.android.library`, so it has **neither task** — its task is `test`.
Gradle runs a task-name request only in projects that have it, so the job reports green while never
executing any of `:core`'s nine test classes, including `SharedProtocolVectorsTest` (the Android half of
the shared wire-format vectors) and `ExactDerTrustManagerTest` (certificate pinning).

**Confirmed here** against the real task graph:

```
$ ./gradlew testDebugUnitTest lintDebug assembleDebug --dry-run | grep -E '^:.*:(test|lint)'
:app:testDebugUnitTest SKIPPED   … :transport:testDebugUnitTest SKIPPED
   (no :core: entry of any kind)
```

Naming the task adds 26 passing tests. **Fixed in PR #23.**

### C-04 · Two of CICD.md's four planned jobs cannot run on their assigned runner — `medium` [S]
The `otp-corpus` job is assigned `ubuntu-latest`, but the corpus is executed only by
`macos/Tests/EkoTests/OTPCorpusTests.swift`, which does `@testable import EkoCore` and link-depends on
AppKit/Security/CoreBluetooth/UserNotifications — `macos/README.md` explicitly says the package will not build
on Linux, and per locked decision D7 there is no Kotlin extractor to run the corpus against. The `protocol`
job has the same shape.

**Fix:** rewrite as three jobs — `android` (ubuntu), `macos` (macos-15, Xcode pinned to `project.yml`, running
`Scripts/verify-macos.sh`, which covers OTP corpus + protocol vectors + migrations in one shot), and
`protocol` (ubuntu, JSON-Schema/data validation only, explicitly scoped).

### C-05 · The entire Android transport session layer and mTLS/pairing client have zero tests — `high` [S]
`NormalPeerSession`, `TlsConnector`, `LanPairingClient`, `ConnectionService`, `TransportRuntime`,
`EligibleNetworkMonitor`, `AppliedReceiptSession` and `Receivers` are referenced by **no test** on either the
JVM or instrumented side. The transport suite covers only the actor, planner, validator, wire JSON and
tombstone. This is starkly asymmetric with the Mac, where `SessionManagerTests.swift` is 38 KB over the same
handshake/backlog/supersession logic — and it is exactly where [B-02](#b-02), [B-13](#b-13) and [B-19](#b-19)
live.

**Fix:** two seams make most of it testable without a device — drive `NormalPeerSession` over an in-memory
frame pipe fed by `protocol/test-vectors/scenarios/*.json` (mirroring what `SessionManagerTests` already
does), and test `TlsConnector`'s pinning against a local `SSLServerSocket` with a known-good and known-bad
leaf.

### C-06 · Seven of eleven shared scenario vectors are consumed by nothing; Android consumes none — `medium` [S]
macOS consumes `pairing-retry`, `resume`, `supersession`, `unpair`. Android consumes **zero** scenarios
(`SharedProtocolVectorsTest` reads only `sas`, `framing`, `malformed-frames`). Unconsumed by anything:
`active-chunks`, `generation-transition`, `invalid-ack`, `multi-mac-retention`, `peer-cursor-regression`,
`retention-gap`, `stale-fetch` — which is to say, the vectors describing precisely the durability edge cases
the design exists to get right. Four of them map directly onto logic already hand-tested in
`EventRepositoryTest.kt` and `EkoStoreTests.swift`; replacing those hand-written fixtures with the shared
vectors is nearly free and turns them into genuine conformance tests.

### C-07 · ~~No JSON Schema validation~~ — **resolved on `main` by #4**
`scripts/check-protocol.py` now loads the schema registry and validates every embedded scenario frame,
and runs as its own CI job. This closes the "the schemas are the field-level source of truth" gap.
What remains open is C-06: seven scenario vectors are validated as *data* but still consumed by no
*test* on either platform, and Android consumes none.

### C-08 · Documentation contradicts the code — `medium` [S]
- ~~README.md and AGENTS.md claim pre-scaffold (M0) status~~ — **resolved on `main` by #4.**
- `docs/diagnostics.md` documents an Android diagnostics export that does not exist.
- The macOS export is a single JSON file, not the ZIP archive the docs tell users to unzip.
- Two user docs instruct a synthetic test notification and a panel keyboard shortcut that were never built.
- `macos/README.md`'s build command omits the destination and code-signing flags the sanctioned gate requires.
- The macOS release checklist's entitlement allowlist omits a shipped, required entitlement.

### C-09 · Supply-chain and tooling gaps — `medium` **[V]**
- **No `Package.resolved` is committed** and `swift-crypto` is pinned as a range, so macOS builds are not
  reproducible.
- ~~Dependabot covers `github-actions` only~~ — **resolved on `main` by #4** (Gradle and Swift added).
- **No version catalog** (`gradle/libs.versions.toml`): `androidx.core:core-ktx:1.17.0` and
  `kotlinx-coroutines:1.10.2` are duplicated verbatim across four and five module files respectively.
- **`:outbox` uses `kapt` for Room** — lint flags it: *"This library supports using KSP instead of kapt,
  which greatly improves performance."* With Kotlin 2.2, kapt is legacy.
- **No test on either platform asserts that a redacted diagnostics export contains no notification content**
  — the one property the redaction contract exists to guarantee.
- Lint also flags 6 `ApplySharedPref` (synchronous `commit()`) sites, two `PluralsCandidate` strings, four
  unused string resources, and `ObsoleteSdkInt` on `ConnectionService.kt:245` and `mipmap-anydpi-v26/`.

---

# I. Aesthetic direction

The individual visual defects are in sections C and E. This section is the *shape* of the answer to
"make it look like a high-value iOS app rather than a mid Android app".

The honest diagnosis: **nothing here was designed; it was assembled.** Every surface is a direct, literal
rendering of a state machine — a card per permission, a row per notification, a `String(describing:)` per
enum. There is no visual hierarchy beyond "things are in a list", no motion, no brand voice, and no shared
vocabulary of radius, spacing, type or colour. That is what reads as "mid Android app", on both platforms.

### I-01 · Build a design-token layer first — `idea`, medium effort
`macos/App/PanelViews.swift` alone uses **seven independently chosen corner radii** — 8 (search field), 9
(gap row, StateCard), 10 (pairing block), 11 (notification row), 12 (verification code), 18 (QR card), plus
Capsules — and every one is a plain `RoundedRectangle(cornerRadius:)` with the default **`.circular`** style.
Apple's own surfaces are squircles (`style: .continuous`); circular corners next to the system's continuous
corners on the same screen is one of the most reliable tells that a Mac app wasn't designed on the platform.

Padding is equally ad-hoc: 4, 5, 6, 7, 8, 9, 10, 11, 12, 18, 56 all appear as bare literals. The type ramp
mixes semantic styles with five absolute sizes (8, 15, 24, 34, 42), and `design: .rounded` appears exactly
once — on the wordmark — so the brand voice exists in one place and nowhere else. Colours are
`Color.primary.opacity(0.05/0.06/0.07)` for what is conceptually one "subtle fill", plus bare `.white`,
`.red`, `.orange`, `.yellow`.

**Do this first, because everything else in this section depends on it.** A small `DesignSystem.swift`:
`Radius` (sm 8 / md 12 / lg 18, all `.continuous`), `Spacing` on a 4 pt grid, `Typography` (a fixed ramp of
named roles, `.rounded` applied consistently to numerals and codes), `Palette` (surface, surfaceRaised,
hairline, accentText, warning, danger — each defined for light *and* dark and reactive to
`colorSchemeContrast`). Then mechanically replace every literal. It is a day of work and it raises perceived
quality more than any single feature.

The Android mirror: generate a full tonal palette from the seed with Material Theme Builder so every `on*`
role is deliberate (today `onSecondary`, `onBackground`, `onSurfaceVariant`, `outline`, `errorContainer` are
left at M3 baseline — **purple-tinted neutrals sitting under a green-tinted surface set**), replace the
`containerColor = …copy(alpha = 0.55f)` calls (an alpha copy means `contentColorFor` can't match the role, so
content silently falls back to `onSurface`), and define a real type ramp with tabular figures for codes and
counts.

### I-02 · Unify the brand across the two halves — `idea`, small effort
macOS ships a teal→blue gradient wave mark (`#22C6B7 → #13759F`) and an AccentColor of teal
`rgb(0.09, 0.62, 0.64)`. Android ships `#075E54` (which is, notably, WhatsApp's green) and a completely
different launcher glyph — a generic phone-with-lines. There is no monochrome layer, so the icon won't theme
on Android 13+. Pick one mark and one palette, derive both platforms' assets from it, and ship the
monochrome layer. This is the cheapest single change with the largest "is this a real product?" payoff.

### I-03 · Design a real OTP card — `idea`, medium effort
The OTP treatment today is the same rounded rectangle as every other row, tinted `accentColor.opacity(0.1)`
with a 0.32-alpha stroke, containing a 24 pt monospaced code and a small bordered-prominent button.
Extracting the code is **the reason the product exists** and the reason someone would pay for it, and it is
rendered as a 10 %-opacity variation on a generic list row. The digits aren't grouped, there's no per-digit
rhythm, the code isn't the visual anchor, and there's no cue that the clipboard auto-clears in 120 s.

Give codes a distinct card: a raised material or full-bleed accent gradient; the code as grouped monospaced
digit tiles (`448 291`) at ~32 pt with tabular figures; the source app as a quiet caption above; a single
large affordance the whole card responds to; a thin auto-clear countdown ring; a subtle scale/glow on first
appearance. **That one card is what the screenshot on the sales page should be.**

Grouping is purely presentational and therefore safe — the extractor already strips spaces and hyphens
during normalization, so the canonical stored form is separator-free. Format 6 digits as 3+3 and 8 as 4+4
with a thin space, leave alphanumeric codes untouched, keep `.textSelection` on the unformatted value, and
set an accessibility label that spells the digits individually so VoiceOver doesn't read "448,291" as a
number.

### I-04 · Add motion — and the accessibility switches that turn it off — `idea`, medium effort
Grepping `macos/App/` for `withAnimation`, `.animation(`, `.transition(` returns **exactly one hit** (the
`scrollTo` on focus change). Grepping the Android app module for `AnimatedVisibility`, `Crossfade`,
`animate*AsState`, `AnimatedContent` returns **zero**. Notifications pop into the list, the feed↔pairing
route swap replaces the whole content instantly, gap rows appear and disappear abruptly, group-by-device
restructures in one frame, hovering snaps a row's height. The result feels less like a native app than like
a web page re-rendering.

Correspondingly, grepping `macos/App/` for `@Environment(\.` returns **zero hits** — the app never reads
`accessibilityReduceMotion`, `accessibilityReduceTransparency`, `colorSchemeContrast` or `dynamicTypeSize`,
so there is nothing to disable and nothing to strengthen when a user turns those on. (`.ultraThinMaterial`
handles Reduce Transparency itself; the four hand-rolled `Color…opacity()` surfaces do not.)

Concretely: a spring on feed insertion
(`.animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.notifications.map(\.id))`), an
asymmetric transition on new rows, a slide or matched-geometry on the route change, `AnimatedContent` with a
shared-axis transition on the Android page switch, `animateColorAsState` on the status chip, and checklist
cards animating as they collapse. All of it gated behind Reduce Motion with a cross-fade fallback.

### I-05 · Make the panel keyboard-first — `idea`, medium effort
`showPanel()` makes the panel key but sets no first responder, and there is no `@FocusState` in the entire
app. So opening the panel and typing does nothing. Escape does nothing predictable, Return does nothing, and
because the feed is a `LazyVStack` rather than a `List` there is no selection model, no arrow navigation and
no focus ring. For a menubar app whose whole value is speed — the code arrives, you need it in the clipboard
in under two seconds — the interaction is currently mouse-only end to end.

Focus search on open via `.defaultFocus`; Escape clears search if non-empty else dismisses; rows focusable
with ↑/↓; Return copies the code (falling back to text); ⌘⌫ dismisses on the phone; `/` focuses search;
⌘1…⌘9 copies the Nth visible code. Combined with the Edit menu from [M-01](#m-01), that turns Eko into
something a power user can drive blind.

### I-06 · Replace the Android checklist wall with a staged pager — `idea`, large effort
`OnboardingScreen` is one `LazyColumn` presenting all eight cards simultaneously — every card shows its full
body copy and its buttons at once, so a first-run user faces ~400 words of system-permission prose and six
buttons before doing anything. The restricted-settings card is shown to *every* Android 13+ user who hasn't
yet granted access, **placed before the notification-access step**, so the first thing a new user reads is a
warning about a failure that has not happened yet.

Restructure as a `HorizontalPager`: one step per page, a progress rail ("3 of 6"), one illustration, one
sentence, one primary button. Show only applicable steps (skip CDM where unavailable; surface
restricted-settings *reactively*, only after `onResume` shows access still denied). End on the missing step 9
— send a test notification, watch it round-trip to the Mac, animate a checkmark — which turns a permissions
gauntlet into a moment of confidence. Keep the all-cards list as the re-entrant Setup tab, collapsed to
one-line rows.

---

# J. Ideas — novel, useful, and a few quirky

Ranked roughly by delight × feasibility. Items marked ⚡ are the cheap ones worth doing first.

### ⚡ J-01 · Make copying a code a *moment* — trivial
Morph the Copy button to a checkmark with `.contentTransition(.symbolEffect(.replace))`, draw a thin 120 s
ring that drains — driven by the same `EkoClock` the controller uses, so the display cannot lie — and fade it
out when the wipe fires. An optional short click sound, off by default, never during backlog replay. Gate
motion on `accessibilityDisplayShouldReduceMotion` and mirror the change into a VoiceOver announcement
("Copied — clears in 2 minutes"). Today the product's central interaction produces **zero** perceptible
response, and the clipboard silently empties two minutes later, which reads as a bug.

### ⚡ J-02 · "Open link on Mac" row action — trivial
Notification bodies already arrive complete and are stored verbatim, and the OTP extractor already carries a
well-tested URL regex which it uses to *delete* URLs before matching. Promote it into a shared
`LinkExtractor`, render an "Open ⟨host⟩" button in the row action strip, `NSWorkspace.shared.open`. Show the
resolved host, never the display text, so a phishing notification can't disguise its destination. Never
auto-open; never open on banner click. "A link arrived on my phone, I want it on my Mac" is a top-three
reason people install a mirroring tool, and today the answer is "retype it". **This is the cheapest genuinely
useful feature on the list.**

### ⚡ J-03 · Per-phone colour identity from the deviceId hash — trivial
`Device.id` is a SHA-256 hex fingerprint, so a stable hue is derivable with zero storage and zero
configuration: `hue = first two bytes / 65535`, snapped to ~12 well-separated hues, with fixed
saturation/brightness for contrast in both appearances. Apply to the chip fill, a 3 pt leading edge on the
row, and the group header glyph. In the two- or three-phone household the product explicitly targets, the
feed is currently a wall of identical rectangles. Keep the device *name* on every surface — this is identity,
not state, but the never-colour-alone rule should still hold. Offer a per-device override in the Devices pane.

### ⚡ J-04 · A right-click status-item menu — trivial
Quit, Settings, Pause banners, Open Eko, Check connections. ~40 lines, and it removes the single most jarring
rough edge in the shipped app (see [M-01](#m-01)). It also gives VoiceOver users a keyboard-navigable surface
for free.

### ⚡ J-05 · Read-friendly OTP grouping, display layer only — trivial
Humans read `448 291` and transcribe `448291`; they misread `448291`. Covered in [I-03](#i-03); listed
separately because it is a 10-line change that can ship independently.

### ⚡ J-06 · Device chips should say *when* the phone was last seen — trivial
PLAN sketches the tooltip as "last seen + state"; the shipped tooltip is state only, and `Device.lastSeen`
already exists and is already rendered relatively in the Devices pane. "Disconnected" with no timestamp is
the difference between "my phone is in the next room" and "my phone has been dead since Tuesday". Then add a
soft *away* distinction: disconnected within ~5 minutes reads as "Away" (hollow ring), older reads as
"Offline · 3 h ago" (struck glyph).

### J-07 · A fourth banner mode: "Codes only" — small
`BannerMode` is `normal | silent | muted`, and the delivery guard already computes
`(outcome.kind == .posted || outcome.otpBannerEligible)` on the very next line after the banner-mode check —
the machinery to say "banner only when this is a code" is literally already in the expression. Nobody ships
this well: for a bank or an authenticator app you want the code and nothing else, and today the only choices
are everything or nothing. Seed it as the default for packages the phone flagged with the existing
"contains OTPs" hint. **Careful:** `banner_mode != 'muted'` is also used as a *feed* filter, so `codesOnly`
must not filter the feed, only banners (see [F-04](#f-04)).

### J-08 · Sticky newest-code card with an honest age meter — small
When you open the panel to fetch a code you currently scroll a chronological list looking for it. Pin the
newest uncopied OTP above the feed for ~3 minutes with a hairline meter that drains, and make Copy the
default (⏎) action. **Resist displaying an expiry countdown** — we cannot know the issuer's TTL, and a wrong
countdown is worse than none. Label it as *age* ("detected 40 s ago"), which is a true statement, and dim the
card once `copiedAt` is set so a copied code stops shouting.

### J-09 · Collapse conversation threads using `group_key` — small
`group_key` is normative in the schema, decoded into `NotificationContent.groupKey` and length-validated —
**and then never persisted**: the `notification` table carries `is_group_summary` but no `group_key`. So the
feed shows fourteen separate rows from one WhatsApp group. This is the "summarize a noisy app" payoff with no
model involved: Android already told us which notifications belong together. Add the column in a forward
migration, add a "Collapse threads" toggle next to "Group by phone", render one row per
`(device, app, group_key)` with an "Anna +13" expander. Bonus: group summaries are currently rendered as
ordinary rows even though `OTPExtractor` deliberately skips them — collapsing gives you a principled place to
hide them.

### J-10 · "Dismiss all" — per app, per phone, or everything — small
`SessionManager.dismiss` already exists and `dismiss` is a negotiated capability; the feed already knows every
active key. Clearing a phone's notification shade from the Mac at the end of the day is a genuinely satisfying
thing nobody does well. Surface it on the group-by-device header, in the row context menu (app-scoped), and in
the right-click status menu. Cap the batch, confirm above ~20, and pace the sends through the outbound actor
rather than blasting.

### J-11 · Wire the per-device pause seam that already exists, plus Focus awareness — small
`NotificationDeliveryPolicy.allowsBanner(deviceID:)` takes a deviceID and the only implementation ignores it
entirely. The seam was designed and then not used; this is a few dozen lines from delivering a promised
feature. Add a `pausedDevices: Set<String>` and an optional "paused until" date. For Focus there's no public
"which Focus is active" API, but `INFocusStatusCenter.default` + `focusStatus.isFocused` gives the boolean,
which is all PLAN needs — it requires the Communication Notifications entitlement and a user prompt, so make
it opt-in and degrade silently. **Add a timed variant ("Pause for 1 hour")**: a pause you can forget you
enabled is a data-loss-shaped UX bug.

### J-12 · First-pairing celebration that doubles as the missing round-trip proof — small
Today, after `PairingConfirmationView` resolves true, `endPairing()` drops the route back to `.feed` and the
user stares at an empty state — **the emotional peak of the product lands on `ContentUnavailableView`.**
Meanwhile Android's checklist is missing PLAN's step 9. Build both halves as one feature: Android adds a
ninth card that posts a local notification from Eko's own package (note `NotificationExtractor.extract`
currently returns null for `sbn.packageName == context.packageName`, so this needs a deliberate allowlisted
test path); the Mac, on the first event from a brand-new device, shows a one-time full-panel success state —
the phone's name settling into the chip row with its new identity colour, "You're mirrored", one button.
Once per device, dismissible, never again.

### J-13 · Global hotkey code-grabber — medium
PLAN specifies it (⌃⇧⌘V, off by default, with a collision warning) and nothing is built. `EkoStore` also has
no "latest OTP across all devices" query — `currentOTP` is keyed to a specific notification. Add
`latestOTP(within:deviceID:)` (the `otp` table already has `detected_at_ms` and `copied_at_ms`), and register
the chord with Carbon `RegisterEventHotKey` — it works **inside the App Sandbox and needs no Accessibility
grant**, unlike `NSEvent.addGlobalMonitorForEvents`. On fire: copy the newest uncopied code, flash a small
centered HUD with the code and source app for ~1.2 s, mark it copied. If no fresh code exists, open the panel
focused on search rather than doing nothing.

### J-14 · A status item that actually conveys state — medium
PLAN specifies a pulse on mirror, a badge dot plus an opt-in code chip that auto-hides after 60 s, a struck
glyph with a *count* badge, and a progress arc during backlog sync. Shipped: four unrelated SF Symbols that
swap the icon's whole identity. Replace `button.image` with a small custom `NSView` drawing a stable template
glyph plus overlays — a count badge for disconnected phones, a dot for a fresh code, an arc driven by backlog
progress (`BacklogSummary` already flows through `AppSessionSink`). Drive a one-shot `Timer` at
`codeReceivedAt + 60` so the code state expires on its own (see [M-08](#m-08)). Gate the pulse on Reduce
Motion; test with a template image in both appearances.

### J-15 · Backlog progress as a compact pill, and the missing inline banner — medium
Backlog completion is currently announced as a separate system `UNNotification` — a banner about banners,
exactly the wrong texture — while during the replay itself the panel shows nothing at all. While any device
is `.synchronizing`, collapse the header title into a pill: device colour dot, name, progress, count so far.
On completion, `matchedGeometryEffect` it into the inline banner row PLAN describes, pinned above the feed
with a [Show] that sets the filters and scrolls to the first replayed row (the replayed clock badge already
exists). Keep the system notification only for when the panel is closed — the case it was actually right for.

### J-16 · Truncation shimmer — small
`truncated_fields` is a required, normative part of every posted/updated event (RFC-6901 pointers), and
`body_complete` is a real column the feed filters on: the system takes "we may not have the whole text"
seriously all the way down. The UI expresses **none** of it — a body the phone truncated at the source looks
identical to one SwiftUI merely clipped. Terminate such text with a short animated gradient shimmer instead
of "…", with a tooltip naming what happened. It reads as a tiny piece of privacy theatre and is also
literally true, which is the best kind. Persist a `truncated` flag alongside `body_complete` so the panel can
tell "clipped by us" from "clipped by Android". Static hatched block under Reduce Motion.

### J-17 · Phone battery and signal glance — medium
Both endpoints already advertise `ext_types`, so a new phone→Mac `phone_status` message is *ignorable by
construction* on any peer that hasn't been updated — the forward-compatibility work is already done (modulo
[B-23](#b-23)). "Is my phone about to die" is exactly the kind of ambient fact a menubar app should answer,
and it's the natural payload for the chip tooltip PLAN already reserves. Keep it in memory only — it is not a
notification and **must never consume a seq**. The real cost isn't the code, it's doing it properly:
`protocol.md` is normative, so it needs a section, a schema and vectors. Budget for that or it will rot.

### J-18 · "Ring my phone" — medium
The Mac→phone control channel already exists and is proven: `dismiss` goes out via `session.transport.send`
and lands on `NotificationListenerController.dismiss`. A `ring` message is the same shape. Phone is in the
sofa, Mac is right there — every household has this daily, and the alternative is a Google account
round-trip. Behind a negotiated `ring` capability. Android: `AudioAttributes.USAGE_ALARM` so it beats silent
mode, escalating volume, a full-screen "Eko is ringing — Stop", auto-stop after 30 s. **Security matters
here:** only over a live confirmed session with a pinned cert, never from a pending pairing, rate-limited
hard, and the phone-side UI must always name which Mac asked and offer "Stop and disable ringing". A
compromised Mac that can make your phone scream at 3 am is a genuinely bad outcome.

### J-19 · Shortcuts / App Intents plus a tiny CLI (`eko code`) — large
Everything an automation surface needs is already a synchronous store read: latest code, codes from an app,
notifications matching a search, dismiss-all, pause banners. `LatestCode`, `CodesFrom(app:)`,
`DismissAllOn(phone:)`, `PauseBannersFor(duration:)` as in-app intents (which work fine for an LSUIElement
app). This is what makes Eko a thing people build workflows around rather than an app they open — "when I
press ⌥Space, paste my latest 2FA code" via Raycast. **Treat it as a security surface:** any local process
reading codes is a real risk, so put it behind an explicit opt-in, log every read into `DiagnosticsRecorder`,
and apply the same auto-clear semantics as the panel.

### J-20 · Auto-paste into the frontmost app — large, and be honest about it
The single most delightful possible behavior: the code arrives, you're already in the Safari 2FA field, and it
types itself. The missing step is synthesizing ⌘V into another process, which requires `CGEventPost` and
therefore an Accessibility grant — **not obtainable in the App Sandbox**, and PLAN deliberately keeps the
sandbox on so a Mac App Store path stays open. Do not quietly drop the sandbox. Ship it as an explicitly
opt-in capability in a Developer-ID (unsandboxed) variant, guarded by `AXIsProcessTrustedWithOptions`
prompting, a per-app allowlist, and a hard rule that it fires only within N seconds of the banner and only
for `originBound` matches — the ones we know are bound to a domain. The safe fallback everywhere else: copy
plus `NSRunningApplication.activate` to bring the target forward so the user only presses ⌘V. Be prepared for
the answer to be "no" for a MAS build, and say so in Settings rather than shipping a toggle that silently
does nothing.

### J-21 · Latest-code widget / Control Center control — large, rank last
An obvious fit, blocked architecturally rather than cosmetically: `EkoStore` opens a fixed path under
Application Support, not an app-group container, and a widget extension is a separate process. Much cheaper
alternative: have the app write a tiny, short-lived JSON snapshot (latest code + app label + detectedAt) to a
group container on each OTP commit and let the widget read only that, sidestepping shared SQLite entirely.
Either way, think hard before putting a live 2FA code on the lock screen — that is a shoulder-surfing
surface, so default it to tap-to-reveal.

### J-22 · Android Home as a dashboard, not a socket readout — medium
`HomeScreen` answers "is the socket up" but not the question the user actually has: "is my Mac getting my
notifications right now". The data to answer it already exists and is unused —
`TransportSnapshot.lastForwardWall` is computed and rendered only in Diagnostics; `Connected` carries
`sinceWall` and `acknowledgedThrough` and both are discarded by `TransportStatus`; `strings.xml` defines
`last_ack` = "Acknowledged through %1$d" and it is **referenced nowhere in the codebase**. Showing
`host:port` and a raw fingerprint prefix as primary content while hiding "last forwarded 4 seconds ago" is
exactly backwards for a consumer product.

Rebuild the peer card around evidence: a large connection state with an animated live dot, "Last mirrored 4 s
ago", "Connected for 2 h 14 m", a sparkline of forwards over the last hour, and the queue depth only when
non-zero. Demote `host:port` and the fingerprint into an expandable Details section. Add a per-Mac "Send test
notification" — it doubles as the missing onboarding step 9 and as the single best answer to "is this thing
on?"

---

## Appendix: verification status

**Machine-verified in this environment.** Android SDK 36 + build-tools 36 + Temurin JDK 17 installed;
`./gradlew :app:assembleDebug`, `./gradlew test`, `./gradlew lint` all run green from a clean checkout
(`BUILD SUCCESSFUL`, 186 and 427 actionable tasks). The Python harness passes: `24 tests, OK`. Findings
marked **[V]** are corroborated by that toolchain — notably [B-12](#b-12) (lint `ImplicitSamInstance` at
`EkoNotificationListener.kt:108`), [C-02](#c-02) (the toolchain failure reproduced verbatim on JDK 21),
[C-03](#c-03) (`:core:test` is not run by `testDebugUnitTest`), [A-14](#a-14) (`ObsoleteSdkInt` on
`mipmap-anydpi-v26/`), and the `ApplySharedPref` / `KaptUsageInsteadOfKsp` / `PluralsCandidate` /
`UnusedResources` items in [C-09](#c-09).

**Not verified by compilation.** There is no Swift toolchain and no macOS host available here, so every
finding in the macOS sections is source-verified only — read against the actual code and cited to
`file:line`, but not compiled and not run. Each was additionally put through an adversarial pass whose
instruction was to refute it and to default to "not real" when it could not be confirmed from the source;
what survives is listed above. Anything depending on runtime AppKit behaviour (window levels, key-equivalent
dispatch, material blending, status-item metrics) should be confirmed on a real Mac before being treated as
settled.
