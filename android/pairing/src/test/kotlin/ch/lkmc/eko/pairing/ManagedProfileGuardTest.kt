package dev.eko.pairing

import android.content.Context
import android.os.UserManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class ManagedProfileGuardTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun `personal profile permits pairing and setup`() {
        Shadows.shadowOf(context.getSystemService(UserManager::class.java)).setManagedProfile(false)

        assertFalse(ManagedProfileGuard.isManagedProfile(context))
        ManagedProfileGuard.requirePersonalProfile(context)
    }

    @Test
    fun `managed profile refuses pairing and setup`() {
        Shadows.shadowOf(context.getSystemService(UserManager::class.java)).setManagedProfile(true)

        assertTrue(ManagedProfileGuard.isManagedProfile(context))
        assertThrows(IllegalStateException::class.java) {
            ManagedProfileGuard.requirePersonalProfile(context)
        }
    }
}
