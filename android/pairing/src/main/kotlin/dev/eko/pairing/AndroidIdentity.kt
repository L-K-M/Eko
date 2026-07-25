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
        if (!keyStore.containsAlias(ALIAS)) generate()
        val privateKey = keyStore.getKey(ALIAS, null) as? PrivateKey
            ?: error("Android Keystore did not return Eko's private key")
        val certificate = keyStore.getCertificate(ALIAS) as? X509Certificate
            ?: error("Android Keystore did not return Eko's certificate")
        val encoded = Base64.encodeToString(certificate.encoded, Base64.NO_WRAP)
        store.persistCertificate(encoded)
        DeviceIdentity(
            certificate = certificate,
            privateKey = privateKey,
            deviceId = certificateFingerprint(certificate.encoded),
            keyManager = PinnedAliasKeyManager(ALIAS, privateKey, certificate),
        )
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
            .setDigests(KeyProperties.DIGEST_SHA256)
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
