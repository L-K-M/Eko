package dev.eko.core

import java.math.BigInteger
import java.security.Principal
import java.security.PublicKey
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Date
import javax.security.auth.x500.X500Principal
import kotlin.test.Test
import kotlin.test.assertFailsWith

class ExactDerTrustManagerTest {
    @Test
    fun `accepts only byte-for-byte leaf DER equality`() {
        val pinned = byteArrayOf(1, 2, 3, 4)
        val manager = ExactDerTrustManager(listOf(pinned))
        manager.checkServerTrusted(arrayOf(EncodedCertificate(pinned.copyOf())), "EC")

        assertFailsWith<CertificateException> {
            manager.checkServerTrusted(arrayOf(EncodedCertificate(byteArrayOf(1, 2, 3, 5))), "EC")
        }
    }

    @Test
    fun `pairing fingerprint is checked against the TLS leaf`() {
        val certificate = byteArrayOf(9, 8, 7)
        ExactDerTrustManager(emptyList(), certificateFingerprint(certificate), false)
            .checkServerTrusted(arrayOf(EncodedCertificate(certificate)), "EC")
        assertFailsWith<CertificateException> {
            ExactDerTrustManager(emptyList(), "0".repeat(64), false)
                .checkServerTrusted(arrayOf(EncodedCertificate(certificate)), "EC")
        }
    }
}

private class EncodedCertificate(private val bytes: ByteArray) : X509Certificate() {
    override fun getEncoded(): ByteArray = bytes.copyOf()
    override fun checkValidity() = Unit
    override fun checkValidity(date: Date?) = Unit
    override fun getVersion(): Int = 3
    override fun getSerialNumber(): BigInteger = BigInteger.ONE
    override fun getIssuerDN(): Principal = X500Principal("CN=issuer")
    override fun getSubjectDN(): Principal = X500Principal("CN=subject")
    override fun getNotBefore(): Date = Date(0)
    override fun getNotAfter(): Date = Date(Long.MAX_VALUE)
    override fun getTBSCertificate(): ByteArray = bytes.copyOf()
    override fun getSignature(): ByteArray = byteArrayOf()
    override fun getSigAlgName(): String = "SHA256withECDSA"
    override fun getSigAlgOID(): String = "1.2.840.10045.4.3.2"
    override fun getSigAlgParams(): ByteArray? = null
    override fun getIssuerUniqueID(): BooleanArray? = null
    override fun getSubjectUniqueID(): BooleanArray? = null
    override fun getKeyUsage(): BooleanArray? = null
    override fun getBasicConstraints(): Int = -1
    override fun verify(key: PublicKey?) = Unit
    override fun verify(key: PublicKey?, sigProvider: String?) = Unit
    override fun getPublicKey(): PublicKey = object : PublicKey {
        override fun getAlgorithm(): String = "EC"
        override fun getFormat(): String = "X.509"
        override fun getEncoded(): ByteArray = byteArrayOf()
    }
    override fun toString(): String = "EncodedCertificate"
    override fun hasUnsupportedCriticalExtension(): Boolean = false
    override fun getCriticalExtensionOIDs(): MutableSet<String>? = null
    override fun getNonCriticalExtensionOIDs(): MutableSet<String>? = null
    override fun getExtensionValue(oid: String?): ByteArray? = null
}
