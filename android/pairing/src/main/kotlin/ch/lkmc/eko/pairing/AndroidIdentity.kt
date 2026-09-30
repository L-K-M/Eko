package dev.eko.pairing

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import dev.eko.core.certificateFingerprint
import java.math.BigInteger
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Calendar
import java.util.Date
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.security.auth.x500.X500Principal
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class DeviceIdentity(
    val certificate: X509Certificate,
    val privateKey: PrivateKey,
    val deviceId: String,
    val keyManager: X509ExtendedKeyManager,
)

object AndroidIdentity {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "eko-device-identity-v1"

    suspend fun getOrCreate(store: IdentityStore): DeviceIdentity = withContext(Dispatchers.IO) {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        var rotated = false
        if (keyStore.containsAlias(ALIAS)) {
            val existingKey = keyStore.getKey(ALIAS, null) as? PrivateKey
            if (existingKey != null && !supportsTlsHandshakeSigning(existingKey) &&
                store.read().confirmedPeers.isEmpty()
            ) {
                keyStore.deleteEntry(ALIAS)
                rotated = true
            }
        }
        if (!keyStore.containsAlias(ALIAS)) generate()
        val privateKey = keyStore.getKey(ALIAS, null) as? PrivateKey
            ?: error("Android Keystore did not return Eko's private key")
        val certificate = keyStore.getCertificate(ALIAS) as? X509Certificate
            ?: error("Android Keystore did not return Eko's certificate")
        val encoded = Base64.encodeToString(certificate.encoded, Base64.NO_WRAP)
        if (rotated) store.resetIdentity(encoded) else store.persistCertificate(encoded)
        DeviceIdentity(
            certificate = certificate,
            privateKey = privateKey,
            deviceId = certificateFingerprint(certificate.encoded),
            keyManager = PinnedAliasKeyManager(ALIAS, privateKey, certificate),
        )
    }

    // TLS client authentication signs a transcript the TLS stack has already
    // hashed: Conscrypt delegates a raw digest to the keystore provider as
    // NONEwithECDSA, and Keymaster refuses that operation unless the key
    // authorizes DIGEST_NONE. A key minted without it can never complete a
    // handshake, so it is rotated — safe while no peer has pinned it, and a
    // peer cannot have pinned it because pairing runs over that handshake.
    private fun supportsTlsHandshakeSigning(privateKey: PrivateKey): Boolean = try {
        val factory = java.security.KeyFactory.getInstance(privateKey.algorithm, KEYSTORE)
        val info = factory.getKeySpec(privateKey, android.security.keystore.KeyInfo::class.java)
        info.digests.contains(KeyProperties.DIGEST_NONE)
    } catch (_: Exception) {
        // Unable to inspect the key: keep it rather than destroy an identity.
        true
    }

    private fun generate() {
        val now = Calendar.getInstance()
        val notBefore = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }.time
        val notAfter = Calendar.getInstance().apply { add(Calendar.YEAR, 20) }.time
        val serial = BigInteger(159, SecureRandom()).setBit(158)
        val subject = X500Principal("CN=Eko Android ${Build.MODEL.take(32).replace(',', ' ')}")
        val specification = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setAlgorithmParameterSpec(java.security.spec.ECGenParameterSpec("secp256r1"))
            // DIGEST_NONE authorizes the raw pre-hashed signing TLS client
            // authentication needs; SHA-256 covers the self-signed certificate.
            .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
            .setCertificateSubject(subject)
            .setCertificateSerialNumber(serial)
            .setCertificateNotBefore(notBefore)
            .setCertificateNotAfter(notAfter)
            .setUserAuthenticationRequired(false)
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).apply {
            initialize(specification)
            generateKeyPair()
        }
    }
}

private class PinnedAliasKeyManager(
    private val alias: String,
    private val privateKey: PrivateKey,
    certificate: X509Certificate,
) : X509ExtendedKeyManager() {
    private val chain = arrayOf(certificate)

    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> = arrayOf(alias)
    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String = alias
    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> = arrayOf(alias)
    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String = alias
    override fun getCertificateChain(requestedAlias: String?): Array<X509Certificate>? = if (requestedAlias == alias) chain.clone() else null
    override fun getPrivateKey(requestedAlias: String?): PrivateKey? = if (requestedAlias == alias) privateKey else null
    override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?): String = alias
    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?): String = alias
}
