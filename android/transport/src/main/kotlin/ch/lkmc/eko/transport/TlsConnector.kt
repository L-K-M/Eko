package dev.eko.transport

import android.net.Network
import android.os.Build
import dev.eko.core.ExactDerTrustManager
import dev.eko.pairing.DeviceIdentity
import dev.eko.pairing.PeerEndpoint
import java.net.InetSocketAddress
import java.security.Provider
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import org.conscrypt.Conscrypt

data class TlsPeerConnection(
    val socket: SSLSocket,
    val peerCertificateDer: ByteArray,
)

class TlsConnector(private val identity: DeviceIdentity) {
    fun connectPinned(
        network: Network,
        endpoint: PeerEndpoint,
        peerCertificateDer: ByteArray,
    ): TlsPeerConnection = connect(
        network,
        endpoint,
        ExactDerTrustManager(listOf(peerCertificateDer)),
    )

    fun connectPairing(
        network: Network,
        endpoint: PeerEndpoint,
        expectedFingerprint: String?,
    ): TlsPeerConnection = connect(
        network,
        endpoint,
        ExactDerTrustManager(
            acceptedCertificates = emptyList(),
            expectedPairingFingerprint = expectedFingerprint?.lowercase(),
            allowUnknownDuringPairing = expectedFingerprint == null,
        ),
    )

    private fun connect(
        network: Network,
        endpoint: PeerEndpoint,
        trustManager: ExactDerTrustManager,
    ): TlsPeerConnection {
        val provider = tlsProvider()
        val context = if (provider == null) {
            SSLContext.getInstance("TLSv1.3")
        } else {
            SSLContext.getInstance("TLSv1.3", provider)
        }
        context.init(arrayOf<KeyManager>(identity.keyManager), arrayOf(trustManager), null)

        val raw = network.socketFactory.createSocket()
        try {
            raw.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
            val socket = context.socketFactory.createSocket(raw, endpoint.host, endpoint.port, true) as SSLSocket
            socket.enabledProtocols = arrayOf("TLSv1.3")
            socket.sslParameters = socket.sslParameters.apply {
                protocols = arrayOf("TLSv1.3")
                endpointIdentificationAlgorithm = null
            }
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            socket.startHandshake()
            check(socket.session.protocol == "TLSv1.3") { "TLS downgrade was refused" }
            val peerDer = socket.session.peerCertificates.first().encoded
            socket.soTimeout = 0
            return TlsPeerConnection(socket, peerDer)
        } catch (error: Throwable) {
            runCatching { raw.close() }
            throw error
        }
    }

    private fun tlsProvider(): Provider? = if (Build.VERSION.SDK_INT <= 28) {
        Conscrypt.newProvider()
    } else {
        null
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000
        const val HANDSHAKE_TIMEOUT_MS = 10_000
    }
}
