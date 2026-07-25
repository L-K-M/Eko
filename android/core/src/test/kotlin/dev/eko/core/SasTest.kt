package dev.eko.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SasTest {
    private val attempt = ByteArray(16) { it.toByte() }
    private val certificateA = byteArrayOf(1, 2, 3)
    private val certificateB = byteArrayOf(0xf0.toByte(), 0xe0.toByte(), 0xd0.toByte())
    private val nonceA = ByteArray(32) { (it + 16).toByte() }
    private val nonceB = ByteArray(32) { (it + 48).toByte() }

    @Test
    fun `commitment matches normative byte construction`() {
        val commitment = Sas.commitment(attempt, certificateA, nonceA)
        assertEquals("e532a6c652e24148166eef0db42a61b03c4ecaf016ff82ddf125dad96c0fc6ba", commitment.hexLower())
        assertTrue(Sas.verifyCommitment(commitment, attempt, certificateA, nonceA))
        assertFalse(Sas.verifyCommitment(commitment, attempt, certificateA, nonceB))
    }

    @Test
    fun `SAS is symmetric and binds each nonce to its certificate`() {
        val code = Sas.verificationCode(attempt, certificateA, nonceA, certificateB, nonceB)
        assertEquals("2DB25B9F", code)
        assertEquals(
            "2db25b9fb32a73179429743c4888ebe8f10ffec31fadcb607e08990de21b6588",
            Sas.transcriptHash(attempt, certificateA, nonceA, certificateB, nonceB),
        )
        assertEquals(code, Sas.verificationCode(attempt, certificateB, nonceB, certificateA, nonceA))
        assertFalse(code == Sas.verificationCode(attempt, certificateA, nonceB, certificateB, nonceA))
    }
}
