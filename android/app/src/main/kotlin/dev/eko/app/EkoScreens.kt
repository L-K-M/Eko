package dev.eko.app

import android.os.Build
import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.HealthAndSafety
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.PauseCircle
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import dev.eko.capture.CaptureHealth
import dev.eko.outbox.AppWithRule
import dev.eko.outbox.StoreDurability
import dev.eko.pairing.CompanionPresence
import dev.eko.pairing.CompanionPresenceState
import dev.eko.pairing.DiscoveredMac
import dev.eko.pairing.IdentityState
import dev.eko.pairing.MacDiscovery
import dev.eko.pairing.UdpHintListener
import dev.eko.transport.PeerTransportState
import dev.eko.transport.TransportSnapshot

private enum class AppPage(val label: Int, val icon: ImageVector) {
    HOME(R.string.nav_home, Icons.Outlined.Home),
    APPS(R.string.nav_apps, Icons.Outlined.Apps),
    DIAGNOSTICS(R.string.nav_diagnostics, Icons.Outlined.HealthAndSafety),
    SETUP(R.string.nav_setup, Icons.Outlined.Settings),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EkoRoot(
    viewModel: EkoViewModel,
    scannerError: String?,
    clearScannerError: () -> Unit,
    openScanner: () -> Unit,
    requestAssociation: (Boolean) -> Unit,
    openNotificationAccess: () -> Unit,
    openAppInfo: () -> Unit,
    requestPostNotifications: () -> Unit,
    requestBatteryExemption: () -> Unit,
) {
    val home by viewModel.home.collectAsStateWithLifecycle()
    val identity by viewModel.identity.collectAsStateWithLifecycle()
    val checks by viewModel.checks.collectAsStateWithLifecycle()
    val pairing by viewModel.pairing.collectAsStateWithLifecycle()
    val apps by viewModel.apps.collectAsStateWithLifecycle()
    val capture by viewModel.captureHealth.collectAsStateWithLifecycle()
    val transport by viewModel.transport.collectAsStateWithLifecycle()
    val store by viewModel.storeHealth.collectAsStateWithLifecycle()
    val presence by CompanionPresenceState.state.collectAsStateWithLifecycle()

    // Setup is where a *new* user starts, not where every launch starts. The start
    // destination used to be a constant, and the only escape was a LaunchedEffect that
    // required `pairing is Success` — a value that is Idle again on every cold process.
    // So a fully-paired, fully-permissioned user opened the app, or tapped the ongoing
    // service notification, and landed on an eight-card permission wall.
    val setupComplete = identity.confirmedPeers.isNotEmpty() && checks.notificationAccess
    var page by rememberSaveable { mutableStateOf<AppPage?>(null) }
    val currentPage = page ?: if (setupComplete) AppPage.HOME else AppPage.SETUP

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (currentPage == AppPage.SETUP) stringResource(R.string.setup_title) else stringResource(R.string.app_name)) },
                actions = {
                    if (currentPage != AppPage.SETUP) {
                        IconButton(onClick = { page = AppPage.SETUP }) {
                            Icon(Icons.Outlined.Add, contentDescription = stringResource(R.string.add_mac))
                        }
                    }
                },
            )
        },
        bottomBar = {
            NavigationBar {
                AppPage.entries.forEach { destination ->
                    NavigationBarItem(
                        selected = currentPage == destination,
                        onClick = { page = destination },
                        icon = { Icon(destination.icon, contentDescription = null) },
                        label = { Text(stringResource(destination.label)) },
                    )
                }
            }
        },
    ) { padding ->
        when (currentPage) {
            AppPage.HOME -> HomeScreen(home, viewModel, Modifier.padding(padding))
            AppPage.APPS -> AppsScreen(apps, viewModel, Modifier.padding(padding))
            AppPage.DIAGNOSTICS -> DiagnosticsScreen(
                identity,
                capture,
                transport,
                store,
                presence,
                checks.recentExitReason,
                viewModel,
                Modifier.padding(padding),
            )
            AppPage.SETUP -> OnboardingScreen(
                identity = identity,
                checks = checks,
                pairing = pairing,
                scannerError = scannerError,
                clearScannerError = clearScannerError,
                viewModel = viewModel,
                openScanner = openScanner,
                requestAssociation = requestAssociation,
                openNotificationAccess = openNotificationAccess,
                openAppInfo = openAppInfo,
                requestPostNotifications = requestPostNotifications,
                requestBatteryExemption = requestBatteryExemption,
                modifier = Modifier.padding(padding),
            )
        }
    }
}

@Composable
private fun OnboardingScreen(
    identity: IdentityState,
    checks: SystemChecks,
    pairing: PairingUiState,
    scannerError: String?,
    clearScannerError: () -> Unit,
    viewModel: EkoViewModel,
    openScanner: () -> Unit,
    requestAssociation: (Boolean) -> Unit,
    openNotificationAccess: () -> Unit,
    openAppInfo: () -> Unit,
    requestPostNotifications: () -> Unit,
    requestBatteryExemption: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val discovery = remember { MacDiscovery(context) }
    val udpHints = remember { UdpHintListener() }
    val scope = rememberCoroutineScope()
    val discovered by discovery.devices.collectAsStateWithLifecycle()
    val announced by udpHints.hints.collectAsStateWithLifecycle()
    DisposableEffect(discovery) {
        discovery.start()
        udpHints.start(scope)
        onDispose {
            discovery.close()
            udpHints.close()
        }
    }
    // Saveable, not remembered: a rotation, fold, dark-mode switch or font-size change
    // recreates the Activity, and losing a manually typed IP address and a 64-hex
    // fingerprint mid-entry is the most annoying possible moment to lose them.
    var host by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf("48808") }
    var fingerprint by rememberSaveable { mutableStateOf("") }
    var token by rememberSaveable { mutableStateOf("") }

    scannerError?.let { error ->
        AlertDialog(
            onDismissRequest = clearScannerError,
            confirmButton = { TextButton(onClick = clearScannerError) { Text(stringResource(android.R.string.ok)) } },
            // Pre-formatted by the caller: scan failures arrive wrapped in
            // pair_error, CDM failures in cdm_failed, permission guidance
            // plain — wrapping again here mislabeled everything as
            // "Pairing failed:".
            title = { Text(error) },
        )
    }
    when (pairing) {
        is PairingUiState.Verify -> AlertDialog(
            onDismissRequest = {},
            confirmButton = {
                Button(onClick = { viewModel.confirmPairing(true) }) { Text(stringResource(R.string.pair_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.confirmPairing(false) }) { Text(stringResource(R.string.pair_reject)) }
            },
            title = { Text(stringResource(R.string.pair_verify_title)) },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.pair_verify_body, pairing.peerName))
                    Spacer(Modifier.height(16.dp))
                    Text(
                        pairing.code,
                        style = MaterialTheme.typography.headlineLarge,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                    )
                }
            },
        )
        else -> Unit
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Text(stringResource(R.string.setup_intro), style = MaterialTheme.typography.bodyLarge)
        }
        if (checks.managedProfile) {
            item {
                ChecklistCard(
                    title = stringResource(R.string.managed_profile_title),
                    body = stringResource(R.string.managed_profile_body),
                    healthy = false,
                )
            }
        }
        item {
            ChecklistCard(
                title = stringResource(R.string.pair_title),
                body = stringResource(R.string.pair_body),
                healthy = identity.confirmedPeers.isNotEmpty(),
            ) {
                if (discovered.isNotEmpty()) {
                    Text(stringResource(R.string.discovered_macs), fontWeight = FontWeight.SemiBold)
                    discovered.forEach { mac ->
                        DiscoveredMacChip(mac) {
                            host = mac.host
                            port = mac.port.toString()
                            fingerprint = mac.fingerprint.orEmpty()
                        }
                    }
                }
                announced.forEach { hint ->
                    AssistChip(
                        onClick = {
                            host = hint.host
                            port = hint.port.toString()
                            fingerprint = hint.fingerprint
                        },
                        label = { Text("${hint.name} · ${hint.host}:${hint.port}") },
                        leadingIcon = { Icon(Icons.Outlined.Link, contentDescription = null) },
                    )
                }
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.host_label)) },
                    singleLine = true,
                )
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it.filter(Char::isDigit).take(5) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.port_label)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = fingerprint,
                    onValueChange = { fingerprint = it.filterNot(Char::isWhitespace).take(64) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.fingerprint_label)) },
                    singleLine = true,
                )
                OutlinedTextField(
                    value = token,
                    onValueChange = { token = it.take(512) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.token_label)) },
                    singleLine = true,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(onClick = openScanner) {
                        Icon(Icons.Outlined.QrCodeScanner, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.scan_qr))
                    }
                    Button(
                        onClick = { viewModel.startPairing(host, port, fingerprint, token) },
                        enabled = host.isNotBlank() && port.isNotBlank() && pairing !is PairingUiState.Connecting &&
                            !checks.managedProfile,
                    ) { Text(stringResource(R.string.pair_action)) }
                }
                if (pairing is PairingUiState.Connecting) Text(stringResource(R.string.pair_connecting))
                if (pairing is PairingUiState.Success) Text(stringResource(R.string.pair_success, pairing.peerName))
                if (pairing is PairingUiState.Failed) {
                    Text(stringResource(R.string.pair_error, pairing.detail), color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = viewModel::clearPairingState) { Text(stringResource(R.string.pair_try_again)) }
                }
                identity.pendingPairings.forEach { pending ->
                    TextButton(onClick = {
                        viewModel.startPairing(
                            pending.endpoint.host,
                            pending.endpoint.port.toString(),
                            pending.peerDeviceId,
                            null,
                            pending.attemptId,
                        )
                    }) { Text(stringResource(R.string.resume_pairing, pending.peerName)) }
                }
            }
        }
        item {
            ChecklistCard(
                title = stringResource(R.string.cdm_title),
                body = stringResource(R.string.cdm_body),
                healthy = identity.associations.isNotEmpty(),
                status = stringResource(if (identity.associations.isNotEmpty()) R.string.cdm_ready else R.string.cdm_needed),
            ) {
                if (!checks.locationEnabled) {
                    Text(stringResource(R.string.location_off), color = MaterialTheme.colorScheme.error)
                    OutlinedButton(onClick = { requestAssociation(true) }) { Text(stringResource(R.string.open_location_settings)) }
                } else {
                    Button(onClick = { requestAssociation(true) }) { Text(stringResource(R.string.cdm_associate)) }
                    TextButton(onClick = { requestAssociation(false) }) { Text(stringResource(R.string.cdm_wifi)) }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= 33 && !checks.notificationAccess) {
            item {
                ChecklistCard(
                    title = stringResource(R.string.restricted_title),
                    body = stringResource(R.string.restricted_body),
                    healthy = null,
                ) {
                    OutlinedButton(onClick = openAppInfo) { Text(stringResource(R.string.open_app_info)) }
                }
            }
        }
        item {
            ChecklistCard(
                title = stringResource(R.string.notification_access_title),
                body = stringResource(R.string.notification_access_body),
                healthy = checks.notificationAccess,
                status = if (checks.notificationAccess) stringResource(R.string.notification_access_ready) else null,
            ) {
                Button(onClick = openNotificationAccess) { Text(stringResource(R.string.open_notification_access)) }
            }
        }
        item {
            ChecklistCard(
                title = stringResource(R.string.post_title),
                body = stringResource(R.string.post_body),
                healthy = checks.postNotifications,
                status = if (checks.postNotifications) stringResource(R.string.post_ready) else null,
            ) {
                if (!checks.postNotifications) {
                    Button(onClick = requestPostNotifications) { Text(stringResource(R.string.post_action)) }
                }
            }
        }
        item {
            ChecklistCard(
                title = stringResource(R.string.battery_title),
                body = stringResource(R.string.battery_body),
                healthy = checks.batteryExempt,
                status = if (checks.batteryExempt) stringResource(R.string.battery_ready) else null,
            ) {
                if (!checks.batteryExempt) {
                    OutlinedButton(onClick = requestBatteryExemption) { Text(stringResource(R.string.battery_action)) }
                }
            }
        }
        item {
            val manufacturer = Build.MANUFACTURER.ifBlank { Build.BRAND }
            ChecklistCard(
                title = stringResource(R.string.oem_title, manufacturer),
                body = stringResource(oemGuideResource(manufacturer)),
                healthy = null,
            ) {
                OutlinedButton(onClick = {
                    val slug = manufacturer.lowercase().replace(" ", "-")
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://dontkillmyapp.com/$slug")))
                }) { Text(stringResource(R.string.oem_guide)) }
            }
        }
    }
}

@Composable
private fun ChecklistCard(
    title: String,
    body: String,
    healthy: Boolean?,
    status: String? = null,
    content: @Composable ColumnScope.() -> Unit = {},
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = when (healthy) {
                true -> MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.55f)
                false -> MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.45f)
                null -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
            },
        ),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    when (healthy) {
                        true -> Icons.Outlined.CheckCircle
                        false -> Icons.Outlined.Warning
                        null -> Icons.Outlined.Info
                    },
                    contentDescription = null,
                )
                Spacer(Modifier.width(10.dp))
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }
            Text(body)
            status?.let { Text(it, fontWeight = FontWeight.Medium) }
            content()
        }
    }
}

@Composable
private fun DiscoveredMacChip(mac: DiscoveredMac, onClick: () -> Unit) {
    AssistChip(
        onClick = onClick,
        label = { Text("${mac.serviceName} · ${mac.host}:${mac.port}") },
        leadingIcon = { Icon(Icons.Outlined.Computer, contentDescription = null) },
    )
}

@Composable
private fun HomeScreen(home: HomeState, viewModel: EkoViewModel, modifier: Modifier = Modifier) {
    // The device id, not the peer object: a HomePeer is not Parcelable, and the
    // confirmation dialog used to vanish mid-decision on any configuration change.
    var unpairDeviceId by rememberSaveable { mutableStateOf<String?>(null) }
    val unpair = unpairDeviceId?.let { id -> home.peers.firstOrNull { it.peer.deviceId == id } }
    unpair?.let { selected ->
        // Three actions, laid out vertically inside `text` rather than crammed into the
        // two button slots. M3's AlertDialogFlowRow can wrap between slots but not
        // inside one, so the previous Row{Forget, Cancel} in the dismissButton slot was
        // atomic and could not fit — "Ohne Benachrichtigung vergessen" alone is 30
        // characters. Stacking also fixes the hierarchy: the irreversible action is now
        // error-coloured and the safe one is the plain confirm.
        AlertDialog(
            onDismissRequest = { unpairDeviceId = null },
            confirmButton = {
                TextButton(onClick = { unpairDeviceId = null }) { Text(stringResource(R.string.cancel)) }
            },
            title = { Text(stringResource(R.string.unpair_title, selected.peer.name)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.unpair_body))
                    Button(
                        onClick = {
                            viewModel.unpair(selected.peer.deviceId)
                            unpairDeviceId = null
                        },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error,
                            contentColor = MaterialTheme.colorScheme.onError,
                        ),
                    ) { Text(stringResource(R.string.unpair)) }
                    OutlinedButton(
                        onClick = {
                            viewModel.unpair(selected.peer.deviceId, notifyPeer = false)
                            unpairDeviceId = null
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text(stringResource(R.string.forget_without_notifying)) }
                    Text(
                        stringResource(R.string.forget_without_notifying_detail),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
        )
    }
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(
                Modifier
                    .fillMaxWidth()
                    .toggleable(
                        value = !home.forwardingPaused,
                        role = Role.Switch,
                        onValueChange = { viewModel.setForwardingPaused(!it) },
                    ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.home_title), style = MaterialTheme.typography.headlineSmall)
                    Text(stringResource(if (home.forwardingPaused) R.string.forwarding_off else R.string.forwarding_on))
                }
                Switch(checked = !home.forwardingPaused, onCheckedChange = null)
            }
        }
        if (home.peers.isEmpty()) item { Text(stringResource(R.string.no_macs)) }
        items(home.peers, key = { it.peer.deviceId }) { peer ->
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Computer, contentDescription = null)
                        Spacer(Modifier.width(10.dp))
                        // The status badge used to sit in this row unweighted, so Compose
                        // measured its full intrinsic width first and the name got the
                        // scraps: "Warten auf WLAN, Ethernet oder VPN" left under 30dp for
                        // a 22sp name on a 360dp phone, wrapping it to one glyph per line.
                        // The badge now owns its own line and the name truncates instead.
                        Text(
                            peer.peer.name,
                            style = MaterialTheme.typography.titleLarge,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    TransportStatus(peer.status)
                    Text(pluralStringResource(R.plurals.queued_events, peer.queuedEvents.toInt(), peer.queuedEvents))
                    Text("${peer.peer.endpoint.host}:${peer.peer.endpoint.port}", fontFamily = FontFamily.Monospace)
                    Text(stringResource(R.string.fingerprint_short, peer.peer.deviceId.take(12)), style = MaterialTheme.typography.bodySmall)
                    OutlinedButton(onClick = { unpairDeviceId = peer.peer.deviceId }) { Text(stringResource(R.string.unpair)) }
                }
            }
        }
    }
}

// Shared by the Home status badge and the Diagnostics peer list — the latter
// used to print `state::class.simpleName`, which is untranslated in debug and
// R8-obfuscated gibberish in release builds.
@Composable
private fun transportStateLabel(status: PeerTransportState): String = when (status) {
    is PeerTransportState.Connected -> stringResource(R.string.status_connected)
    is PeerTransportState.Syncing -> stringResource(R.string.status_syncing, status.eventCount)
    is PeerTransportState.Reconnecting -> stringResource(R.string.status_reconnecting, status.nextDelayMillis / 1_000.0)
    PeerTransportState.WaitingForNetwork -> stringResource(R.string.status_waiting_network)
    PeerTransportState.Paused -> stringResource(R.string.status_paused)
    PeerTransportState.Offline -> stringResource(R.string.status_offline)
    // An arbitrary-length exception message does not belong in a status badge.
    is PeerTransportState.Failed -> stringResource(R.string.status_failed, status.reason.take(FAILURE_REASON_CHARS))
}

@Composable
private fun TransportStatus(status: PeerTransportState) {
    val text = transportStateLabel(status)
    val icon = when (status) {
        is PeerTransportState.Connected -> Icons.Outlined.CheckCircle
        PeerTransportState.Paused -> Icons.Outlined.PauseCircle
        is PeerTransportState.Failed -> Icons.Outlined.Warning
        else -> Icons.Outlined.Refresh
    }
    val tone = when (status) {
        is PeerTransportState.Connected -> MaterialTheme.colorScheme.primaryContainer
        is PeerTransportState.Failed -> MaterialTheme.colorScheme.errorContainer
        else -> MaterialTheme.colorScheme.surfaceVariant
    }
    // A Surface, not an AssistChip. AssistChip wraps a clickable Surface with
    // Role.Button, so TalkBack announced this as an actionable button whose double-tap
    // did nothing — it is a readout, not a control. Merged semantics so it is announced
    // once, as one phrase.
    Surface(
        shape = MaterialTheme.shapes.small,
        color = tone,
        modifier = Modifier.semantics(mergeDescendants = true) {},
    ) {
        Row(
            Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
            Text(text, style = MaterialTheme.typography.labelLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

private const val FAILURE_REASON_CHARS = 60

@Composable
private fun AppsScreen(apps: List<AppWithRule>, viewModel: EkoViewModel, modifier: Modifier = Modifier) {
    LazyColumn(modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp)) {
        item {
            Text(stringResource(R.string.apps_title), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.apps_intro), modifier = Modifier.padding(vertical = 8.dp))
        }
        if (apps.isEmpty()) item { Text(stringResource(R.string.apps_empty)) }
        items(apps, key = { "${it.userId}:${it.packageName}" }) { app ->
            Card(Modifier.padding(vertical = 6.dp)) {
                Column(Modifier.padding(14.dp)) {
                    Text(app.label, style = MaterialTheme.typography.titleMedium)
                    Text("${app.packageName} · ${stringResource(R.string.user_id, app.userId)}", style = MaterialTheme.typography.bodySmall)
                    RuleSwitch(stringResource(R.string.app_forward), app.enabled) { viewModel.updateRule(app, enabled = it) }
                    RuleSwitch(stringResource(R.string.app_ongoing), app.includeOngoing) { viewModel.updateRule(app, ongoing = it) }
                    RuleSwitch(stringResource(R.string.app_otp), app.otpHint) { viewModel.updateRule(app, otp = it) }
                }
            }
        }
    }
}

@Composable
private fun RuleSwitch(label: String, checked: Boolean, changed: (Boolean) -> Unit) {
    // toggleable on the row, onCheckedChange = null on the control. Without this the
    // label and the switch are unrelated semantics nodes: TalkBack reads the text, then
    // separately reads an unnamed "on, switch", and tapping the label — the natural
    // target and most of the row's width — does nothing. On the Apps screen that was
    // three unlabelled switches per app card.
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(value = checked, role = Role.Switch, onValueChange = changed)
            .minimumInteractiveComponentSize(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = null)
    }
}

@Composable
private fun DiagnosticsScreen(
    identity: IdentityState,
    capture: CaptureHealth,
    transport: TransportSnapshot,
    store: StoreDurability,
    presence: CompanionPresence,
    recentExitReason: Int?,
    viewModel: EkoViewModel,
    modifier: Modifier = Modifier,
) {
    val now = rememberTickingWallClock()
    LazyColumn(
        modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { Text(stringResource(R.string.diagnostics_title), style = MaterialTheme.typography.headlineSmall) }
        item {
            DiagnosticCard(stringResource(R.string.store_health)) {
                Text(when (store) {
                    StoreDurability.Opening -> stringResource(R.string.store_opening)
                    is StoreDurability.Healthy -> stringResource(R.string.store_healthy)
                    is StoreDurability.Unhealthy -> stringResource(R.string.store_unhealthy, store.reason)
                })
            }
        }
        item {
            DiagnosticCard(stringResource(R.string.listener_health)) {
                Text(stringResource(if (capture.listenerConnected) R.string.listener_connected else R.string.listener_disconnected))
                Text(stringResource(R.string.last_callback, relativeTime(capture.lastCallbackWall, now)))
                Text(stringResource(R.string.last_commit, relativeTime(capture.lastCommitWall, now)))
                Text(stringResource(R.string.writer_queue, capture.queueDepth, capture.overflowCount))
                Text(
                    stringResource(if (capture.redactionDetected) R.string.redaction_broken else R.string.redaction_ok),
                    color = if (capture.redactionDetected) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                )
                OutlinedButton(onClick = viewModel::repairListener) { Text(stringResource(R.string.run_repair)) }
            }
        }
        item {
            DiagnosticCard(stringResource(R.string.association_health)) {
                Text(pluralStringResource(R.plurals.association_count, identity.associations.size, identity.associations.size))
                Text(stringResource(R.string.applied_receipts, identity.appliedUnpairReceipts.size))
                Text(stringResource(R.string.presence_state, presenceLabel(presence)))
                identity.associations.forEach { association ->
                    Text("#${association.id} ${association.displayName ?: association.address.orEmpty()}", fontFamily = FontFamily.Monospace)
                    if (Build.VERSION.SDK_INT >= 31) {
                        RuleSwitch(stringResource(R.string.presence_toggle), association.presenceEnabled) {
                            viewModel.setPresenceObservation(association.id, it)
                        }
                    }
                }
                identity.appliedUnpairReceipts.forEach { receipt ->
                    Text("${receipt.deviceId.take(12)} · ${receipt.unpairId}", fontFamily = FontFamily.Monospace)
                    TextButton(onClick = { viewModel.forgetAppliedReceipt(receipt.unpairId) }) {
                        Text(stringResource(R.string.forget_without_notifying))
                    }
                }
            }
        }
        item {
            DiagnosticCard(stringResource(R.string.transport_health)) {
                Text(stringResource(if (transport.serviceRunning) R.string.transport_running else R.string.transport_stopped))
                recentExitReason?.let { Text(stringResource(R.string.recent_exit_reason, it.toString())) }
                transport.peers.forEach { (id, state) ->
                    Text("${id.take(12)}: ${transportStateLabel(state)}")
                    Text(stringResource(R.string.last_forward, relativeTime(transport.lastForwardWall[id] ?: 0, now)))
                }
            }
        }
        item {
            DiagnosticCard(stringResource(R.string.connection_log)) {
                if (transport.recentLog.isEmpty()) Text(stringResource(R.string.never))
                transport.recentLog.asReversed().forEach { Text(it, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace) }
            }
        }
    }
}

@Composable
private fun DiagnosticCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            content()
        }
    }
}

/**
 * A clock that actually ticks.
 *
 * `System.currentTimeMillis()` read during composition is not snapshot state, so
 * `relativeTime` only recomputed when its `wall` argument changed. That is precisely
 * inverted from what a diagnostics screen needs: while the listener is healthy
 * CaptureHealth emits often and the value looks live, but the moment the listener dies —
 * the one situation this screen exists to diagnose — nothing emits, and the screen keeps
 * insisting the last callback was "3 minutes ago" indefinitely.
 */
@Composable
private fun rememberTickingWallClock(): Long {
    val now by produceState(System.currentTimeMillis()) {
        while (true) {
            value = System.currentTimeMillis()
            delay(1_000)
        }
    }
    return now
}

@Composable
private fun relativeTime(wall: Long, now: Long): String = if (wall <= 0) {
    stringResource(R.string.never)
} else {
    DateUtils.getRelativeTimeSpanString(wall, now, DateUtils.SECOND_IN_MILLIS).toString()
}

// presence.event carries internal tokens ("none", "appeared", "disappeared",
// or "presence:<n>" from the API-36 callback); showing them verbatim left
// untranslated identifiers on the Diagnostics screen.
@Composable
private fun presenceLabel(presence: CompanionPresence): String = when {
    presence.event == "none" -> stringResource(R.string.presence_none)
    presence.event == "appeared" || presence.present -> stringResource(R.string.presence_appeared)
    else -> stringResource(R.string.presence_disappeared)
}

private fun oemGuideResource(manufacturer: String): Int = when (manufacturer.lowercase()) {
    "samsung" -> R.string.oem_samsung
    "xiaomi", "redmi" -> R.string.oem_xiaomi
    "huawei", "honor" -> R.string.oem_huawei
    "oneplus" -> R.string.oem_oneplus
    else -> R.string.oem_generic
}
