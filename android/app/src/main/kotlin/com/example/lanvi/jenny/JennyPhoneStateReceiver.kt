// Purpose: Detect a likely missed call locally and send a fixed, rate-limited SMS without using AI.
// Integration: Receives PHONE_STATE broadcasts; READ_PHONE_STATE and READ_CALL_LOG are required.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Adds normal-mode missed-call note; only saved, non-blocked contacts get automatic replies.

package com.example.lanvi.jenny

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import android.telephony.TelephonyManager
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.Executors

class JennyPhoneStateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        val prefs = context.getSharedPreferences("lanvi_jenny_runtime", Context.MODE_PRIVATE)
        when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> {
                val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER).orEmpty()
                prefs.edit().putString("ringing_number", number).putLong("ringing_at", System.currentTimeMillis()).putBoolean("ring_answered", false).apply()
            }
            TelephonyManager.EXTRA_STATE_OFFHOOK -> prefs.edit().putBoolean("ring_answered", true).apply()
            TelephonyManager.EXTRA_STATE_IDLE -> {
                val number = prefs.getString("ringing_number", "").orEmpty()
                val ringingAt = prefs.getLong("ringing_at", 0L)
                val answered = prefs.getBoolean("ring_answered", false)
                prefs.edit().remove("ringing_number").remove("ringing_at").remove("ring_answered").apply()
                if (number.isBlank() || answered || System.currentTimeMillis() - ringingAt > 5 * 60 * 1000L) return
                val pending = goAsync()
                EXECUTOR.execute {
                    try {
                        // Give the system call log time to persist the missed-call row.
                        Thread.sleep(1200)
                        processLikelyMissedCall(context.applicationContext, number, ringingAt)
                    } catch (error: Exception) {
                        Log.w("LanviJenny", "Missed-call follow-up skipped safely", error)
                    } finally {
                        pending.finish()
                    }
                }
            }
        }
    }

    private fun processLikelyMissedCall(context: Context, number: String, ringingAt: Long) {
        if (context.checkSelfPermission(android.Manifest.permission.READ_CALL_LOG) != android.content.pm.PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(android.Manifest.permission.SEND_SMS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val policy = JennyRuntimePolicy.read(context)
        if (JennyRuntimePolicy.text(policy, "mode", "normal") != "normal" || !JennyRuntimePolicy.bool(policy, "autoReplyMissedCalls", true)) return
        if (JennyRuntimePolicy.isBlocked(policy, number) || !JennyRuntimePolicy.isSavedContact(context, number)) return
        if (isNotActuallyMissed(context, number, ringingAt)) return

        val prefs = context.getSharedPreferences("lanvi_jenny_runtime", Context.MODE_PRIVATE)
        val key = "missed_reply_${JennyRuntimePolicy.normalize(number)}"
        val now = System.currentTimeMillis()
        if (now - prefs.getLong(key, 0L) < 4 * 60 * 60 * 1000L) return
        val message = JennyRuntimePolicy.text(
            policy,
            "missedCallMessage",
            "Hi, I'm Jenny, Mayank's AI personal assistant. Sorry, Mayank was unable to attend your call. Was it something important? Please leave a message and I will let him know when he checks his phone. Thank you.",
        )
        try {
            val manager = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) context.getSystemService(android.telephony.SmsManager::class.java) else {
                @Suppress("DEPRECATION")
                android.telephony.SmsManager.getDefault()
            } ?: return
            val parts = manager.divideMessage(message)
            if (parts.size <= 1) manager.sendTextMessage(number, null, message, null, null)
            else manager.sendMultipartTextMessage(number, null, parts, null, null)
            prefs.edit().putLong(key, now).apply()
        } catch (error: Exception) {
            Log.w("LanviJenny", "Missed-call SMS not sent", error)
        }
    }

    private fun isNotActuallyMissed(context: Context, number: String, ringingAt: Long): Boolean {
        return try {
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.TYPE, CallLog.Calls.DATE),
                "${CallLog.Calls.DATE} >= ?",
                arrayOf((ringingAt - 5000L).toString()),
                "${CallLog.Calls.DATE} DESC",
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return true
                val lastNumber = cursor.getString(0).orEmpty()
                val type = cursor.getInt(1)
                val date = cursor.getLong(2)
                type != CallLog.Calls.MISSED_TYPE ||
                    JennyRuntimePolicy.normalize(lastNumber) != JennyRuntimePolicy.normalize(number) ||
                    date < ringingAt - 5000L
            } ?: true
        } catch (_: SecurityException) {
            true
        } catch (_: Exception) {
            true
        }
    }

    companion object {
        private val EXECUTOR = Executors.newSingleThreadExecutor()
    }
}
