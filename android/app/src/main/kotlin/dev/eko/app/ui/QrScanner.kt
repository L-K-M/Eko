package dev.eko.app.ui

import android.annotation.SuppressLint
import androidx.activity.compose.BackHandler
import androidx.camera.core.CameraControl
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FlashlightOff
import androidx.compose.material.icons.outlined.FlashlightOn
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import dev.eko.app.R
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private val RETICLE_SIZE = 260.dp
private val RETICLE_RADIUS = 28.dp

@androidx.annotation.OptIn(ExperimentalGetImage::class)
@SuppressLint("UnsafeOptInUsageError")
@Composable
fun QrScanner(
    onResult: (String) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    val executor = remember { Executors.newSingleThreadExecutor() }
    val delivered = remember { AtomicBoolean(false) }
    val scanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build(),
        )
    }
    val providerFuture = remember { ProcessCameraProvider.getInstance(context) }
    var cameraControl by remember { mutableStateOf<CameraControl?>(null) }
    var hasTorch by remember { mutableStateOf(false) }
    var torchOn by remember { mutableStateOf(false) }
    var detected by remember { mutableStateOf(false) }

    // The scanner replaces the whole UI tree rather than being a navigation destination,
    // so without this Back exits the app while the user is pointing the camera at their
    // Mac — and with targetSdk 36 they get the predictive-back app-dismiss preview
    // animation as they do it.
    BackHandler { onClose() }

    DisposableEffect(lifecycleOwner) {
        providerFuture.addListener({
            val provider = providerFuture.get()
            val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(executor) { imageProxy ->
                val mediaImage = imageProxy.image
                if (mediaImage == null || delivered.get()) {
                    imageProxy.close()
                } else {
                    scanner.process(InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees))
                        .addOnSuccessListener { barcodes ->
                            val value = barcodes.firstNotNullOfOrNull(Barcode::getRawValue)
                            if (value != null && delivered.compareAndSet(false, true)) {
                                detected = true
                                onResult(value)
                            }
                        }
                        .addOnCompleteListener { imageProxy.close() }
                }
            }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }.getOrNull()?.let { camera ->
                cameraControl = camera.cameraControl
                hasTorch = camera.cameraInfo.hasFlashUnit()
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            if (providerFuture.isDone) runCatching { providerFuture.get().unbindAll() }
            scanner.close()
            executor.shutdown()
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
        ReticleOverlay(detected = detected)

        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                // The overlay lives outside any Scaffold, so without this the close
                // button sits under a three-button navigation bar.
                .safeDrawingPadding()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                stringResource(R.string.scan_instruction),
                color = Color.White,
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.bodyLarge,
            )
            Button(onClick = onClose) { Text(stringResource(R.string.close_scanner)) }
        }

        if (hasTorch) {
            FilledTonalIconToggleButton(
                checked = torchOn,
                onCheckedChange = {
                    torchOn = it
                    cameraControl?.enableTorch(it)
                },
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .safeDrawingPadding()
                    .padding(16.dp),
            ) {
                Icon(
                    if (torchOn) Icons.Outlined.FlashlightOn else Icons.Outlined.FlashlightOff,
                    contentDescription = stringResource(R.string.scan_torch),
                )
            }
        }
    }
}

/**
 * A dimming scrim with a rounded cut-out, plus a stroke around the cut-out.
 *
 * The previous overlay was `Box(...).size(260.dp).background(Color.Transparent, ...)`,
 * which paints transparent over transparent — the aiming guide was invisible and the
 * user got a bare full-bleed camera feed with nothing to aim. The cut-out needs an
 * offscreen compositing layer so `BlendMode.Clear` punches through the scrim rather
 * than through everything drawn below it.
 */
@Composable
private fun ReticleOverlay(detected: Boolean) {
    val stroke by animateFloatAsState(if (detected) 5f else 2.5f, label = "reticleStroke")
    val tint = MaterialTheme.colorScheme.primary

    Canvas(
        Modifier
            .fillMaxSize()
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen),
    ) {
        val side = RETICLE_SIZE.toPx().coerceAtMost(size.minDimension * 0.8f)
        val topLeft = Offset((size.width - side) / 2f, (size.height - side) / 2f)
        val radius = CornerRadius(RETICLE_RADIUS.toPx())

        drawRect(Color.Black.copy(alpha = 0.55f))
        drawRoundRect(
            color = Color.Transparent,
            topLeft = topLeft,
            size = Size(side, side),
            cornerRadius = radius,
            blendMode = BlendMode.Clear,
        )
        drawRoundRect(
            color = if (detected) tint else Color.White.copy(alpha = 0.9f),
            topLeft = topLeft,
            size = Size(side, side),
            cornerRadius = radius,
            style = Stroke(width = stroke.dp.toPx()),
        )
    }
}
