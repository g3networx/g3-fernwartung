package com.carriez.flutter_hbb

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.os.Build
import android.widget.Toast
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/** Stages a verified APK in Android's installer and handles the system confirmation. */
internal class OpsLinxUpdateInstaller(private val activity: Activity) {
    private val installer get() = activity.packageManager.packageInstaller
    private var active: InstallRequest? = null

    @Synchronized
    private fun takeRequest(request: InstallRequest): Boolean {
        if (active != null || activity.isDestroyed) return false
        active = request
        return true
    }

    @Synchronized
    private fun releaseRequest(request: InstallRequest) {
        if (active === request) active = null
    }

    @Synchronized
    fun close() {
        active?.finish()
    }

    @Synchronized
    fun showPendingConfirmation() {
        active?.showConfirmation()
    }

    fun installVerified(apk: File, result: MethodChannel.Result) {
        val request = InstallRequest(result)
        if (!takeRequest(request)) {
            activity.runOnUiThread {
                result.error("installer_unavailable", "Another installation is in progress", null)
            }
            return
        }
        try {
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(activity.packageName)
                setSize(apk.length())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                }
            }
            val sessionId = installer.createSession(params)
            request.sessionId = sessionId
            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, apk.length()).use { output ->
                    apk.inputStream().use { input -> check(input.copyTo(output) == apk.length()) }
                    session.fsync(output)
                }
                activity.runOnUiThread { request.commit() }
            }
        } catch (_: Exception) {
            activity.runOnUiThread { request.fail("installer_unavailable", "Android could not stage the update") }
        }
    }

    private inner class InstallRequest(private val result: MethodChannel.Result) : BroadcastReceiver() {
        private val action = activity.packageName + ".UPDATE_" + UUID.randomUUID()
        var sessionId = -1
        private var registered = false
        private var finished = false
        private var replied = false
        private var callback: PendingIntent? = null
        private var confirmation: Intent? = null

        fun commit() {
            if (finished) {
                runCatching { installer.abandonSession(sessionId) }
                return
            }
            try {
                ContextCompat.registerReceiver(
                    activity, this, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED
                )
                registered = true
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                val pending = PendingIntent.getBroadcast(
                    activity, sessionId, Intent(action).setPackage(activity.packageName), flags
                )
                callback = pending
                installer.openSession(sessionId).use { it.commit(pending.intentSender) }
            } catch (_: Exception) {
                fail("installer_unavailable", "Android could not start the update")
            }
        }

        @Suppress("DEPRECATION")
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != action ||
                intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != sessionId) return
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    if (replied) return
                    confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    if (confirmation == null) {
                        fail("installer_unavailable", "Android did not provide an installation dialog")
                    } else {
                        showConfirmation()
                    }
                }
                PackageInstaller.STATUS_SUCCESS -> {
                    if (!replied) result.success(true)
                    replied = true
                    finish(abandon = false)
                }
                PackageInstaller.STATUS_FAILURE_ABORTED -> {
                    if (!replied) result.success(false)
                    replied = true
                    finish(abandon = false)
                }
                PackageInstaller.STATUS_FAILURE_BLOCKED ->
                    fail("installer_blocked", "Android blocked the installation", "Android hat die Installation blockiert.")
                else -> fail("installer_failed", "Android rejected the update", "Android konnte das Update nicht installieren.")
            }
        }

        fun showConfirmation() {
            if (!activity.hasWindowFocus()) return
            val pending = confirmation ?: return
            confirmation = null
            try {
                activity.startActivity(pending)
                replied = true
                result.success(true)
            } catch (_: Exception) {
                fail("installer_unavailable", "Android confirmation could not be opened")
            }
        }

        fun fail(code: String, reason: String, message: String? = null) {
            if (finished) return
            if (!replied) {
                result.error(code, reason, null)
                replied = true
            } else if (message != null) {
                Toast.makeText(activity, message, Toast.LENGTH_LONG).show()
            }
            finish()
        }

        fun finish(abandon: Boolean = true) {
            if (finished) return
            finished = true
            if (registered) activity.unregisterReceiver(this)
            callback?.cancel()
            if (abandon && sessionId >= 0) runCatching { installer.abandonSession(sessionId) }
            releaseRequest(this)
        }
    }
}
