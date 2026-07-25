package dev.eko.transport

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.io.Closeable
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first

class EligibleNetworkMonitor(context: Context) : Closeable {
    private val connectivity = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val mutableNetworks = MutableStateFlow<List<Network>>(emptyList())
    val networks = mutableNetworks.asStateFlow()
    private val mutableChanges = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val changes = mutableChanges.asSharedFlow()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refresh()
        override fun onLost(network: Network) = refresh()
        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) = refresh()
    }

    init {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
            .build()
        connectivity.registerNetworkCallback(request, callback)
        refresh()
    }

    suspend fun awaitNetwork(): Network = networks.filter(List<Network>::isNotEmpty).first().first()

    private fun refresh() {
        mutableNetworks.value = connectivity.allNetworks.filter(::isEligible)
        mutableChanges.tryEmit(Unit)
    }

    private fun isEligible(network: Network): Boolean {
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    override fun close() {
        runCatching { connectivity.unregisterNetworkCallback(callback) }
    }
}
