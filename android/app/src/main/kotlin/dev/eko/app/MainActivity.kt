package dev.eko.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.eko.app.ui.EkoTheme
import dev.eko.app.ui.QrScanner
import dev.eko.capture.NotificationListenerController
import dev.eko.pairing.AssociationEvent
import dev.eko.pairing.CdmAssociationController
import dev.eko.pairing.PairingQr
import java.util.UUID
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val viewModel: EkoViewModel by viewModels()

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { EkoTheme { EkoApp(viewModel) } }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshSystemChecks()
    }
}

@Composable
private fun EkoApp(viewModel: EkoViewModel) {
    val context = LocalContext.current
    val activity = context as ComponentActivity
    val scope = rememberCoroutineScope()
    // Saveable: a rotation used to close the scanner, restart the camera, and drop an
    // unread error dialog.
    var scannerVisible by rememberSaveable { mutableStateOf(false) }
    var scannerError by rememberSaveable { mutableStateOf<String?>(null) }
    val controller = remember {
        CdmAssociationController(context) {
            NotificationListenerController.supportedRebind(context)
        }
    }
    val associationLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            scope.launch {
                controller.associationResultCompleted()
                viewModel.refreshSystemChecks()
            }
        }
    }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        viewModel.refreshSystemChecks()
    }
    // Resolved during composition (not context.getString in the callbacks) so
    // the messages track locale/config changes — and to satisfy the
    // LocalContextGetResourceValueCall lint check. The templates keep their
    // %1$s placeholder until formatted at the call site.
    val cameraPermissionMessage = stringResource(R.string.camera_permission_needed)
    val pairErrorTemplate = stringResource(R.string.pair_error)
    val cdmFailedTemplate = stringResource(R.string.cdm_failed)
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        scannerVisible = granted
        // A permanently denied permission resolves instantly with no system
        // dialog; without feedback the primary "Scan QR code" button just
        // looks dead.
        if (!granted) scannerError = cameraPermissionMessage
    }

    if (scannerVisible) {
        QrScanner(
            onResult = { raw ->
                try {
                    val payload = PairingQr.parse(raw)
                    scannerVisible = false
                    viewModel.startPairing(
                        payload.endpoint.host,
                        payload.endpoint.port.toString(),
                        payload.certificateFingerprint,
                        payload.token,
                    )
                } catch (error: Throwable) {
                    scannerError = pairErrorTemplate.format(error.message ?: error.javaClass.simpleName)
                    scannerVisible = false
                }
            },
            onClose = { scannerVisible = false },
        )
        return
    }

    EkoRoot(
        viewModel = viewModel,
        scannerError = scannerError,
        clearScannerError = { scannerError = null },
        openScanner = {
            if (androidx.core.content.ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) scannerVisible = true else cameraPermission.launch(Manifest.permission.CAMERA)
        },
        requestAssociation = { ble ->
            if (!controller.isLocationEnabled()) {
                context.startActivity(controller.locationSettingsIntent())
            } else {
                scope.launch {
                    val events = if (ble) {
                        controller.requestBle(EKO_BLE_SERVICE_UUID)
                    } else {
                        controller.requestWifiFallback()
                    }
                    events.collect { event ->
                        when (event) {
                            is AssociationEvent.Prompt -> associationLauncher.launch(
                                IntentSenderRequest.Builder(event.intentSender).build(),
                            )
                            is AssociationEvent.Created -> viewModel.refreshSystemChecks()
                            // Not a pairing failure — label it as the CDM
                            // association problem it is.
                            is AssociationEvent.Failed ->
                                scannerError = cdmFailedTemplate.format(event.reason)
                        }
                    }
                }
            }
        },
        openNotificationAccess = { context.startActivity(NotificationListenerController.settingsIntent(context)) },
        openAppInfo = {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")),
            )
        },
        requestPostNotifications = {
            if (Build.VERSION.SDK_INT >= 33) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        },
        requestBatteryExemption = {
            val direct = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${context.packageName}"),
            )
            runCatching { context.startActivity(direct) }.getOrElse {
                context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
        },
    )
}

private val EKO_BLE_SERVICE_UUID: UUID = UUID.fromString("72c6f4e8-cc7b-4ea8-9657-8dbb49e7d041")
