package dev.eko.pairing

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import java.io.Closeable
import java.net.InetAddress
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class DiscoveredMac(
    val serviceName: String,
    val host: String,
    val port: Int,
    val fingerprint: String?,
    val lastSeenWall: Long,
)

class MacDiscovery(context: Context) : Closeable {
    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(NsdManager::class.java)
    private val multicastLock = appContext.getSystemService(WifiManager::class.java)
        .createMulticastLock("eko-pairing-scan")
        .apply { setReferenceCounted(false) }
    private val mutable = MutableStateFlow<List<DiscoveredMac>>(emptyList())
    val devices: StateFlow<List<DiscoveredMac>> = mutable.asStateFlow()
    private val resolveQueue = ConcurrentLinkedQueue<NsdServiceInfo>()
    private val resolving = AtomicBoolean(false)
    private var started = false

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) = Unit
        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            resolveQueue += serviceInfo
            resolveNext()
        }
        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            val lostAt = System.currentTimeMillis()
            mutable.value = mutable.value.map { device ->
                if (device.serviceName == serviceInfo.serviceName) device.copy(lastSeenWall = lostAt - LOST_DEBOUNCE_MS) else device
            }
        }
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = close()
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
    }

    fun start() {
        if (started) return
        started = true
        multicastLock.acquire()
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (!resolving.compareAndSet(false, true)) return
        val service = resolveQueue.poll() ?: run {
            resolving.set(false)
            return
        }
        nsd.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = finishedResolve()
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val host = serviceInfo.host?.hostAddress
                if (host != null && serviceInfo.port in 1..65_535) {
                    val fingerprint = serviceInfo.attributes["fp"]?.toString(Charsets.UTF_8)
                    val resolved = DiscoveredMac(
                        serviceName = serviceInfo.serviceName,
                        host = host,
                        port = serviceInfo.port,
                        fingerprint = fingerprint,
                        lastSeenWall = System.currentTimeMillis(),
                    )
                    mutable.value = (mutable.value.filterNot { it.serviceName == resolved.serviceName } + resolved)
                        .filter { System.currentTimeMillis() - it.lastSeenWall <= LOST_DEBOUNCE_MS }
                        .sortedBy(DiscoveredMac::serviceName)
                }
                finishedResolve()
            }
        })
    }

    private fun finishedResolve() {
        resolving.set(false)
        resolveNext()
    }

    override fun close() {
        if (!started) return
        started = false
        runCatching { nsd.stopServiceDiscovery(discoveryListener) }
        if (multicastLock.isHeld) multicastLock.release()
    }

    companion object {
        private const val SERVICE_TYPE = "_eko._tcp."
        private const val LOST_DEBOUNCE_MS = 5_000L
    }
}
