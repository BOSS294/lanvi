// Purpose: Screen carrier calls locally using the user-selected Android call-screening role.
// Integration: Declared in AndroidManifest.xml as a CallScreeningService.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: No AI/network calls; only explicit blocklist and Busy/Sleep policy can decline calls.

package com.example.lanvi.jenny

import android.content.Context
import android.telecom.Call
import android.telecom.CallScreeningService
import android.telephony.SmsManager
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.Executors

class JennyCallScreeningService : CallScreeningService() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun onScreenCall(details: Call.Details) {
        val policy = JennyRuntimePolicy.read(this)
        val handle = details.handle?.schemeSpecificPart.orEmpty()
        val incoming = details.callDirection == Call.Details.DIRECTION_INCOMING
        val known = JennyRuntimePolicy.isSavedContact(this, handle)
        val blocked = handle.isNotBlank() &&
            JennyRuntimePolicy.bool(policy, "blockKnownSpam", true) &&
            JennyRuntimePolicy.isBlocked(policy, handle)
        val priority = JennyRuntimePolicy.isPriority(policy, handle)
        val mode = JennyRuntimePolicy.text(policy, "mode", "normal")
        val shouldReject = incoming && !priority && (
            blocked ||
                (mode in listOf("busy", "sleep") && known && JennyRuntimePolicy.bool(policy, "autoDeclineBusySleep", false)) ||
                (mode in listOf("busy", "sleep") && !known && JennyRuntimePolicy.bool(policy, "blockUnknownCallers", false))
            )

        val response = CallResponse.Builder()
            .setDisallowCall(shouldReject)
            .setRejectCall(shouldReject)
            .setSkipNotification(false)
            .build()

        // The framework requires a response within five seconds; no network/AI work is done here.
        respondToCall(details, response)

        if (JennyRuntimePolicy.bool(policy, "overlayEnabled", false) && android.provider.Settings.canDrawOverlays(this)) {
            try {
                val overlay = android.content.Intent(this, JennyCallOverlayService::class.java)
                    .setAction(JennyCallOverlayService.ACTION_SHOW)
                    .putExtra("number", handle)
                    .putExtra("displayName", if (known) handle else "Incoming caller")
                    .putExtra("decision", if (shouldReject) "Declined by Jenny's local rule" else "Allowed by Jenny's local rule")
                if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(overlay) else startService(overlay)
            } catch (error: Exception) {
                Log.w("LanviJenny", "Optional call overlay could not be shown", error)
            }
        }

        if (shouldReject && known && !blocked && JennyRuntimePolicy.bool(policy, "autoReplyBusySleep", true)) {
            executor.execute {
                sendModeReplyIfNotRecentlySent(handle, mode, policy)
            }
        }
    }

    private fun sendModeReplyIfNotRecentlySent(number: String, mode: String, policy: JSONObject) {
        if (checkSelfPermission(android.Manifest.permission.SEND_SMS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val prefs = getSharedPreferences("lanvi_jenny_runtime", Context.MODE_PRIVATE)
        val key = "reply_cooldown_${JennyRuntimePolicy.normalize(number)}"
        val now = System.currentTimeMillis()
        if (now - prefs.getLong(key, 0L) < 4 * 60 * 60 * 1000L) return
        val message = if (mode == "sleep") {
            JennyRuntimePolicy.text(policy, "sleepMessage", "Hi, I'm Jenny, Mayank's AI assistant. Mayank is resting. If this is important, please leave a message and I will flag it for him. Thank you.")
        } else {
            JennyRuntimePolicy.text(policy, "busyMessage", "Hi, I'm Jenny, Mayank's AI assistant. Mayank is busy. If this is important, please leave a message and I will flag it for him. Thank you.")
        }
        try {
            sendMessage(number, JennyRuntimePolicy.renderAssistantName(policy, message))
            prefs.edit().putLong(key, now).apply()
        } catch (error: Exception) {
            Log.w("LanviJenny", "Busy/Sleep SMS could not be sent", error)
        }
    }

    internal fun sendMessage(number: String, message: String) {
        val manager = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        } ?: return
        val parts = manager.divideMessage(message)
        if (parts.size <= 1) manager.sendTextMessage(number, null, message, null, null)
        else manager.sendMultipartTextMessage(number, null, parts, null, null)
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }
}
