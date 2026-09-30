package dev.eko.pairing

import android.content.Context
import android.os.Build
import android.os.UserManager

object ManagedProfileGuard {
    fun isManagedProfile(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            context.getSystemService(UserManager::class.java).isManagedProfile

    fun requirePersonalProfile(context: Context) {
        check(!isManagedProfile(context)) {
            "Eko cannot capture or pair inside a managed profile; install it in the personal profile"
        }
    }
}
