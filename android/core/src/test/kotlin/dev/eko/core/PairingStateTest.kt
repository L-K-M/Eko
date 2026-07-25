package dev.eko.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs

class PairingStateTest {
    @Test
    fun `confirmation is impossible before commitment and reveal`() {
        val machine = PairingMachine("attempt", expiresAtMillis = 10_000)
        assertFailsWith<IllegalArgumentException> { machine.reduce(PairingAction.ConfirmLocal, 1) }
    }

    @Test
    fun `idempotent terminal state survives duplicate results`() {
        var machine = PairingMachine("attempt", expiresAtMillis = 10_000)
        machine = machine.reduce(PairingAction.TlsReady, 1)
        machine = machine.reduce(PairingAction.LocalCommitSent, 2)
        machine = machine.reduce(PairingAction.PeerCommitReceived, 3)
        machine = machine.reduce(PairingAction.RevealVerified("AB12CD34"), 4)
        machine = machine.reduce(PairingAction.ConfirmPeer, 5)
        machine = machine.reduce(PairingAction.ConfirmLocal, 6)

        assertIs<PairingPhase.Confirmed>(machine.phase)
        assertEquals(machine, machine.reduce(PairingAction.ConfirmPeer, 7))
    }

    @Test
    fun `expired pending attempt cannot be resumed`() {
        val machine = PairingMachine("attempt", expiresAtMillis = 100)
            .reduce(PairingAction.TlsReady, 100)
        assertIs<PairingPhase.Expired>(machine.phase)
    }
}
