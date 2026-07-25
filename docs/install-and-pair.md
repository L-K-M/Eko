# Install and pair Eko

## Requirements

- A Mac running macOS 14 Sonoma or newer.
- An Android phone running Android 8.0/API 26 or newer.
- Both devices connected to the same Wi-Fi or Ethernet LAN for v1. Cellular-only and Internet relay
  connections are not supported.
- A non-guest network that allows clients to reach each other. AP isolation can block discovery and
  direct connections.
- Device Location Services enabled while Android's companion-device picker scans. Eko does not need
  app location permission for this scan.
- Administrator credentials may be needed to move Eko to `/Applications`. Android developer mode
  and `adb` are not required for normal setup.

Eko must be installed in the Android personal profile. Android ignores notification-listener
services installed inside a managed work profile. A personal-profile install may receive work
notifications only when the organization's device policy permits it.

## Install the Mac app

1. Download the macOS artifact and its published checksum from the same Eko release.
2. Verify the checksum before opening the artifact.
3. Move Eko to `/Applications`. Launch-at-login registration is unreliable outside that folder.
4. Open Eko. A production release must identify as Developer ID signed and notarized without asking
   you to bypass Gatekeeper.
5. Keep the menubar app running while pairing.

Eko may ask for these macOS permissions:

| Permission | Why | If denied |
|---|---|---|
| Local Network | Publish and browse discovery hints | Bonjour-based discovery is disabled. The phone can still make an authenticated direct connection using QR/manual details. |
| Bluetooth | Advertise Eko's BLE service for Android companion association and optional Android 16 presence | Notification transport still works. Pairing falls back to a Wi-Fi access-point association and loses BLE presence benefits. |
| Notifications | Show mirrored banners and the Copy code action | Notifications remain available in Eko's panel. |

On macOS 15 and newer, accepting the phone's incoming TCP connection does not itself require Local
Network permission. Do not weaken firewall or router security merely to clear a discovery warning.

If launch at login reports **Requires approval**, open System Settings from Eko and approve Eko in
**General > Login Items & Extensions**.

## Install the Android app

Eko is sideloaded; it is not distributed through Google Play.

### Browser or file-manager install

1. Download the release APK and checksum from the official Eko release page.
2. Verify the checksum on a trusted computer when practical.
3. Open the APK on the phone.
4. If Android blocks it, allow **Install unknown apps** only for the browser or file manager that
   opened this APK.
5. Install Eko, then turn that install-source permission off again unless you intentionally use it
   for future Eko updates.

### Obtainium install

1. Add Eko's official release repository to Obtainium.
2. Confirm that the source resolves to the expected repository and release channel.
3. Install the APK through Obtainium.
4. Keep Obtainium's own unknown-app installation permission only if it will manage updates.

An update must be signed by the same Android release certificate as the installed version. Never
uninstall merely to work around an update-signature error: uninstalling erases the outbox, identity,
pairings, notification-access grant, and companion-device associations. Report the mismatched
artifact instead.

## Pair the first phone

1. On the Mac, choose **Add phone**. Eko enters pairing mode for a short, bounded period and shows a
   QR code plus manual host and port details.
2. On Android, open Eko and choose **Pair with Mac**.
3. Prefer **Scan QR code**. Camera access is optional and is used only for scanning. If camera access
   is denied, select the discovered Mac or enter the displayed host and port manually.
4. For discovery pairing, compare the eight-character verification code on both devices exactly.
   Reject the attempt if either character or the device name differs. QR pairing validates a
   single-use token and still displays the code for reassurance.
5. Confirm on both devices. Normal notification traffic does not start until both confirmations are
   durably recorded.
6. If Android shows a companion-device dialog, select the Mac advertising Eko. This association is
   needed before Android 15/16 OTP text can be considered available. Keep Location Services on until
   the picker completes.
7. If BLE association is unavailable or Mac Bluetooth permission is denied, accept Eko's Wi-Fi
   access-point association fallback. The listed device is the current router, not an assertion that
   the router is the paired Mac.
8. On Android 13 or newer, perform **Allow restricted settings** if Android blocks notification
   access. Follow [Android access and OTP repair](android-access-and-otp-repair.md).
9. Enable **Notification access** for Eko. Read Android's warning: this access allows Eko to read
   notification content and dismiss clearable notifications.
10. Allow ordinary Android notifications for Eko if you want the connection-service status and
    repair alerts visible. Forwarding can run when this permission is denied, but its foreground
    service may be less obvious.
11. Optionally grant **Maximum reliability** battery exemption, then complete any manufacturer
    guidance shown by Eko.
12. Send Eko's synthetic test notification. Setup is complete only when the Mac confirms receipt.

Do not test setup with a real banking OTP. The synthetic notification should contain no personal or
usable credential.

## Add another phone or Mac

Choose **Add phone** on the Mac for each phone. Each phone has an independent certificate, cursor,
backlog, and retention state.

To pair one phone with another Mac, start a new pairing from that Mac. Android's CDM trust is
app/user-wide, so an existing usable association can satisfy OTP trust for all paired Macs. An
additional Mac-specific BLE association may still be offered for Android 16 presence reliability.
Removing one pairing must not remove the last association while another Mac remains paired.

A newly paired Mac starts at the phone's current high-water mark. It does not receive notification
history captured before pairing.

## Discovery and connection troubleshooting

Try these in order:

1. Confirm both devices are on the same LAN. Disable cellular-only mode and temporarily disconnect a
   phone VPN if it routes or blocks local traffic. Eko does not take over Android's VPN slot.
2. Avoid guest Wi-Fi, wireless client isolation, and enterprise networks that prohibit peer traffic.
3. Keep the Mac awake and Eko open during first pairing.
4. Use the QR/manual host and port path. Discovery is only a hint; the pinned TLS certificate defines
   identity.
5. If TCP port `48808` is occupied, use the actual fallback port Eko displays. Do not assume the
   default port after a bind warning.
6. If Bonjour is denied on the Mac, either grant Local Network permission in **System Settings >
   Privacy & Security > Local Network** or continue with direct pairing.
7. If a previously paired phone has a new certificate after reinstall or data reset, use the guided
   **Identity changed - re-pair required** flow. Never accept the old device name as proof of identity.

UDP port `48809` and Bonjour `_eko._tcp` improve discovery but are not required once the phone has a
working last-known address. Do not expose either Eko port to the public Internet.

## Pause, unpair, and remove Eko

- **Pause** intentionally stops forwarding without deleting identity or history. After Android Task
  Manager Stop, Eko records a paused state on the next start and requires an explicit Resume.
- **Connected unpair** is preferred. Eko exchanges an authenticated unpair acknowledgement, removes
  that pairing's data, and removes only companion associations no remaining pairing needs.
- **Offline unpair** immediately blocks normal traffic and deletes local history/cursors. A minimal
  revoked tombstone remains solely to deliver an authenticated unpair on next contact.
- Use **Forget without notifying** only when the other endpoint is permanently unavailable. It
  deliberately abandons that final unpair acknowledgement.
- Uninstalling Android Eko or deleting its app data creates a new identity on reinstall. Re-pair all
  Macs.

Before removing the Mac app, unpair every phone and delete retained history from Eko settings. Before
removing the Android app, let every connected unpair finish so other endpoints do not retain stale
pairings.
