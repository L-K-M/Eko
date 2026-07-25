# Battery and OEM reliability

## What reliability settings can and cannot do

Eko's committed phone outbox is the recovery mechanism. Battery settings improve connection latency
and the chance that Android keeps delivering notification callbacks, but no setting guarantees a
permanent socket or bounded reconnect while a phone is in deep idle.

Do not diagnose an OEM kill from notification silence. Normal silence, Do Not Disturb, app-side
filtering, network loss, and a sleeping Mac can look the same. Show OEM guidance only when Eko has
concrete evidence such as a process-exit record, listener disconnect, repeated foreground-service
start denial, or committed-but-unsent backlog growth.

## Baseline setup for every phone

1. Keep at least one Eko companion-device association. On Android 12-15 this normally supplies Doze,
   restricted-bucket, and permission-auto-revoke exemptions.
2. On Android 16, enable Eko's optional BLE presence association if low-latency reconnect matters.
   Android 16 gates the companion power exemption on BLE presence. The Wi-Fi access-point association
   still provides OTP trust but cannot provide presence.
3. In Eko setup, optionally choose **Maximum reliability** and approve **Allow battery usage without
   restrictions**. Eko shows live state from `PowerManager`; do not assume the dialog succeeded.
4. Allow Eko's ordinary notifications so the foreground connection status remains visible. Denial
   does not stop the service, but it makes its state easier to miss.
5. Do not swipe Eko away as a supposed Android optimization. Recents behavior is OEM-specific and is
   not a correctness control on stock Android.
6. After reboot, unlock the phone once. Credential-encrypted app data and some listener behavior are
   unavailable before first unlock.
7. Keep automatic time enabled when possible. Eko orders by sequence rather than clock, but accurate
   clocks make diagnostics understandable.

Eko's target attributed battery cost is below 2 percent per day on a Pixel-class phone. If a setting
materially increases drain, capture a controlled 24-hour comparison before retaining it. A high
system-wide battery percentage without per-app attribution is not enough evidence.

## Samsung / One UI

Menu names vary by One UI release. Use Settings search when a path has moved.

1. Open **Settings > Apps > Eko > Battery** and choose **Unrestricted**.
2. Open **Settings > Battery and device care > Battery > Background usage limits > Never auto sleeping
   apps** and add Eko.
3. Check **Sleeping apps** and **Deep sleeping apps** on the same screen. Remove Eko if present.
4. Leave **Put unused apps to sleep** enabled for other apps if desired. Adding Eko to **Never auto
   sleeping apps** is narrower than disabling the device-wide feature.
5. Recheck these lists after a major One UI update or device migration; Samsung can rebuild them.

Samsung may classify an app as unused after roughly three days. Validate with a multi-day idle soak,
not only a ten-minute foreground test.

Reference: [dontkillmyapp.com/samsung](https://dontkillmyapp.com/samsung)

## Xiaomi / Redmi / POCO / MIUI / HyperOS

1. Open Eko **App info > Battery saver** or **Battery** and choose **No restrictions**.
2. Enable **Autostart** or **Background autostart** for Eko. It may appear under **Settings > Apps >
   Permissions > Background autostart** or in Xiaomi's Security app.
3. Open recents, locate Eko, and use the lock action if the firmware offers it. Treat this as an OEM
   latency hint, not a replacement for the durable outbox.
4. Confirm Eko is not listed in a battery or memory cleaner's automatic cleanup set.
5. Repeat the checks after HyperOS/MIUI upgrades; these controls are sometimes reset.

If the phone exposes both Android's battery-optimization exemption and Xiaomi's **No restrictions**,
enable both for maximum reliability. They control different layers.

Reference: [dontkillmyapp.com/xiaomi](https://dontkillmyapp.com/xiaomi)

## Huawei / Honor / EMUI

1. Open **Settings > Battery > App launch**.
2. Find Eko and turn off **Manage automatically**.
3. Enable all available manual switches: **Auto-launch**, **Secondary launch**, and **Run in
   background**.
4. Open **Settings > Apps > Eko > Battery** and allow background activity or choose the unrestricted
   option if present.
5. Exclude Eko from cleanup/optimizer actions and lock it in recents if the firmware offers that
   control.

Some Huawei firmware includes PowerGenie behavior that still terminates non-whitelisted processes.
There may be no complete app-side remedy. Eko must report this as a connectivity limitation, preserve
committed rows, and replay after the user next opens the app; it must not claim continuous capture.

Reference: [dontkillmyapp.com/huawei](https://dontkillmyapp.com/huawei)

## OnePlus / OxygenOS

1. Open **Settings > Apps > App management > Eko > Battery usage**.
2. Enable **Allow background activity** and any separate **Allow auto launch** option.
3. Open **Settings > Battery > More settings > Optimize battery use**, select Eko, and choose **Don't
   optimize**. On other OxygenOS versions this is **Apps > Special app access > Battery optimization**.
4. If recents offers a lock action, lock Eko during reliability testing. Do not treat it as the only
   protection.
5. Check that sleep standby or aggressive overnight optimization has not added Eko to a restricted
   list after an OS update.

Reference: [dontkillmyapp.com/oneplus](https://dontkillmyapp.com/oneplus)

## Validate the result

Use a synthetic notification with no private content.

1. Note the phone's generation, last committed sequence, per-Mac acknowledged sequence, floor, and
   queued count.
2. Turn the screen off and leave the phone unplugged for at least one normal idle interval.
3. Post synthetic notifications while the Mac is awake, while it sleeps, and while Wi-Fi is briefly
   unavailable.
4. Wake/unlock the phone and Mac. Confirm every committed sequence is represented on the Mac by an
   event or explicit retention gap.
5. Confirm backlog replay produces one summary rather than a banner storm.
6. Inspect process-exit reason, listener transitions, foreground-service start results, and backlog
   growth. Do not infer failure from a quiet callback timestamp.
7. Repeat over 24 hours before concluding that an OEM setting fixed or caused battery drain.

If a user intentionally selected Android Task Manager **Stop**, Eko must remain paused after the next
start until the user chooses Resume. Reliability guidance must not be used to fight an explicit stop.

## Revert excessive access

The user can return Eko to optimized battery mode, disable optional BLE presence, remove it from OEM
allowlists, or deny Eko notifications. Explain the expected tradeoff: committed events still replay,
but capture availability and reconnect latency become more dependent on Android/OEM scheduling.
