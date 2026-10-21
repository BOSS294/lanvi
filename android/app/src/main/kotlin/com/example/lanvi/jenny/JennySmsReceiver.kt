// Purpose: Local SMS automation. Filters spam/OTP/business messages before any Groq request.
// Integration: Registered for SMS_RECEIVED; requires user-granted SMS/Contacts permissions.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Adds saved-contact-only AI replies, deterministic Busy/Sleep responses, emergency alerts, and rate limits.

package com.example.lanvi.jenny

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

class JennySmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = try { Telephony.Sms.Intents.getMessagesFromIntent(intent).toList() } catch (_: Exception) { return }
        if (messages.isEmpty()) return
        val sender = messages.firstOrNull()?.originatingAddress.orEmpty()
        val body = messages.joinToString(separator = "") { it.messageBody.orEmpty() }.trim()
        val sentAt = messages.firstOrNull()?.timestampMillis ?: System.currentTimeMillis()
        if (sender.isBlank() || body.isBlank()) return
        val pending = goAsync()
        EXECUTOR.execute {
            try {
                process(context.applicationContext, sender, body, sentAt)
            } catch (error: Exception) {
                Log.w("LanviJenny", "Incoming SMS policy failed safely", error)
            } finally {
                pending.finish()
            }
        }
    }

    private fun process(context: Context, sender: String, body: String, sentAt: Long) {
        val policy = JennyRuntimePolicy.read(context)
        if (JennyRuntimePolicy.isBlocked(policy, sender)) return
        // Jenny is not allowed to chat with unknown numbers; this keeps spam/business traffic token-free.
        if (!JennyRuntimePolicy.isSavedContact(context, sender)) return
        if (JennyRuntimePolicy.isLikelyAutomatedOrSpam(sender, body)) return

        val prefs = context.getSharedPreferences("lanvi_jenny_runtime", Context.MODE_PRIVATE)
        val digest = MessageDigest.getInstance("SHA-256").digest("$sender|$sentAt|$body".toByteArray()).joinToString("") { "%02x".format(it) }
        if (prefs.getBoolean("sms_seen_$digest", false)) return
        prefs.edit().putBoolean("sms_seen_$digest", true).apply()

        if (JennyRuntimePolicy.bool(policy, "emergencyAlertsEnabled", true)) {
            val normalizedSender = JennyRuntimePolicy.normalize(sender)
            val pendingKey = "emergency_pending_$normalizedSender"
            val pendingUntil = prefs.getLong(pendingKey, 0L)
            val now = System.currentTimeMillis()
            if (JennyRuntimePolicy.isEmergencyConfirmation(body) && pendingUntil >= now) {
                prefs.edit().remove(pendingKey).apply()
                notifyEmergency(context, sender, body)
                sendEmergencyAcknowledgement(context, sender, prefs)
                return
            }
            if (JennyRuntimePolicy.isEmergency(body)) {
                // First ask the saved contact to confirm; no Groq tokens are spent in this path.
                prefs.edit().putLong(pendingKey, now + 10 * 60 * 1000L).apply()
                val promptKey = "emergency_question_$normalizedSender"
                if (now - prefs.getLong(promptKey, 0L) >= 2 * 60 * 1000L) {
                    val prompt = "Hi, I'm ${JennyRuntimePolicy.assistantName(policy)}, Mayank's AI personal assistant. Is this an emergency that needs Mayank immediately? Reply YES EMERGENCY within 10 minutes to trigger his emergency alert. If someone is in immediate danger, contact local emergency services now. Thank you."
                    try {
                        sendSms(context, sender, prompt)
                        prefs.edit().putLong(promptKey, now).apply()
                    } catch (error: Exception) {
                        Log.w("LanviJenny", "Emergency confirmation SMS failed", error)
                    }
                }
                notifyMayank(context, sender, "Possible emergency awaiting confirmation: ${body.take(220)}", urgent = true)
                return
            }
        }

        val mode = JennyRuntimePolicy.text(policy, "mode", "normal")
        if (mode == "busy" || mode == "sleep") {
            if (JennyRuntimePolicy.bool(policy, "autoReplyBusySleep", true)) {
                val reply = if (mode == "sleep") {
                    JennyRuntimePolicy.text(policy, "sleepMessage", "Hi, I'm Jenny, Mayank's AI assistant. Mayank is resting. If this is important, please leave a message and I will flag it for him. Thank you.")
                } else {
                    JennyRuntimePolicy.text(policy, "busyMessage", "Hi, I'm Jenny, Mayank's AI assistant. Mayank is busy. If this is important, please leave a message and I will flag it for him. Thank you.")
                }
                sendDeterministicSms(context, sender, JennyRuntimePolicy.renderAssistantName(policy, reply), prefs)
                notifyMayank(context, sender, "${mode.uppercase()} mode message: ${body.take(220)}", urgent = false)
            }
            return
        }

        if (!JennyRuntimePolicy.bool(policy, "aiSmsRepliesEnabled", false)) return
        // Local-only mode is an absolute gate: do not read a key or make a network request.
        if (JennyRuntimePolicy.bool(policy, "localOnlyMode", false)) {
            sendDeterministicSms(
                context,
                sender,
                JennyRuntimePolicy.renderAssistantName(policy, "Hi, I'm Jenny, Mayank's AI personal assistant. I've received your message, but online AI is disabled right now. If it is important, please reply YES EMERGENCY so I can alert Mayank; otherwise I'll flag it for him to read when available. Thank you."),
                prefs,
            )
            return
        }
        val key = JennyKeyVault(context).get("groq")
        val lastAiAt = prefs.getLong("ai_last_${JennyRuntimePolicy.normalize(sender)}", 0L)
        if (System.currentTimeMillis() - lastAiAt < 15 * 1000L) return
        if (key.isNullOrBlank()) {
            sendDeterministicSms(
                context,
                sender,
                JennyRuntimePolicy.renderAssistantName(policy, "Hi, I'm Jenny, Mayank's personal AI assistant. I received your message, but online AI is not configured on this device. If this is important, please leave a short message and I will flag it for Mayank. Thank you."),
                prefs,
            )
            return
        }
        if (!withinAiRateLimit(prefs, sender)) return
        val generated = requestJennyReply(key, policy, prefs, sender, body)
        val reply = generated ?: JennyRuntimePolicy.renderAssistantName(
            policy,
            "Hi, I'm Jenny, Mayank's personal AI assistant. I received your message, but online AI is unavailable right now. If this is important, please reply with a short message and I will flag it for Mayank when he checks his phone. Thank you.",
        )
        try {
            sendSms(context, sender, reply)
            prefs.edit().putLong("ai_last_${JennyRuntimePolicy.normalize(sender)}", System.currentTimeMillis()).apply()
            if (Regex("important|urgent|call me|please call|emergency|help", RegexOption.IGNORE_CASE).containsMatchIn(body)) {
                notifyMayank(context, sender, "Important message from $sender: ${body.take(220)}", urgent = true)
            }
            val historyKey = "ai_context_${JennyRuntimePolicy.normalize(sender)}"
            if (generated != null) {
                val prior = prefs.getString(historyKey, "").orEmpty()
                val next = (prior + "\nContact: " + body.take(600) + "\nJenny: " + reply.take(600)).takeLast(2800)
                prefs.edit().putString(historyKey, next).apply()
            }
        } catch (error: Exception) {
            Log.w("LanviJenny", "AI/fallback SMS reply failed to send", error)
        }
    }

    private fun withinAiRateLimit(prefs: android.content.SharedPreferences, sender: String): Boolean {
        val number = JennyRuntimePolicy.normalize(sender)
        val now = System.currentTimeMillis()
        val hour = now / (60 * 60 * 1000L)
        val key = "ai_rate_${number}_$hour"
        val count = prefs.getInt(key, 0)
        if (count >= 8) return false
        prefs.edit().putInt(key, count + 1).apply()
        return true
    }

    private fun requestJennyReply(
        apiKey: String,
        policy: JSONObject,
        prefs: android.content.SharedPreferences,
        sender: String,
        body: String,
    ): String? {
        var connection: HttpURLConnection? = null
        return try {
            val model = JennyRuntimePolicy.text(policy, "groqModel", "openai/gpt-oss-20b")
            val contextText = JennyRuntimePolicy.text(policy, "approvedContext", "Mayank is unavailable right now. Jenny may only share information explicitly approved in this context.")
            val conversation = prefs.getString("ai_context_${JennyRuntimePolicy.normalize(sender)}", "").orEmpty().takeLast(2200)
            val assistantName = JennyRuntimePolicy.assistantName(policy)
            val system = "You are $assistantName, Mayank's disclosed AI personal assistant. Your main purpose is to communicate Mayank's availability, collect the caller's or contact's important message, and say you will flag it for Mayank. Respond only to the saved contact's question using the approved context and short recent conversation. Never reveal private information, credentials, addresses, private conversations, or anything not in this context. If a contact explicitly says this is an emergency, do not try to solve it through AI; say you are alerting Mayank and recommend local emergency services if someone is in immediate danger. Keep replies under 55 words. Identify yourself as an AI assistant; never pretend to be Mayank. Approved context: $contextText\nRecent conversation: $conversation"
            val url = URL("https://api.groq.com/openai/v1/chat/completions")
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 2500
                readTimeout = 3000
                doOutput = true
                setRequestProperty("Authorization", "Bearer $apiKey")
                setRequestProperty("Content-Type", "application/json")
            }
            val payload = JSONObject()
                .put("model", model)
                .put("temperature", 0.2)
                .put("max_tokens", 130)
                .put("messages", JSONArray()
                    .put(JSONObject().put("role", "system").put("content", system))
                    .put(JSONObject().put("role", "user").put("content", "Saved contact sent this SMS: $body")))
            connection.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode !in 200..299) return null
            val response = BufferedReader(InputStreamReader(connection.inputStream)).use { it.readText() }
            val choices = JSONObject(response).optJSONArray("choices") ?: return null
            val message = choices.optJSONObject(0)?.optJSONObject("message") ?: return null
            message.optString("content").trim().takeIf { it.isNotBlank() }?.take(1500)
        } catch (error: Exception) {
            Log.w("LanviJenny", "Groq SMS response was skipped", error)
            null
        } finally {
            connection?.disconnect()
        }
    }

    private fun sendDeterministicSms(context: Context, number: String, text: String, prefs: android.content.SharedPreferences) {
        if (context.checkSelfPermission(android.Manifest.permission.SEND_SMS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val key = "reply_cooldown_${JennyRuntimePolicy.normalize(number)}"
        val now = System.currentTimeMillis()
        if (now - prefs.getLong(key, 0L) < 4 * 60 * 60 * 1000L) return
        try {
            sendSms(context, number, text)
            prefs.edit().putLong(key, now).apply()
        } catch (error: Exception) {
            Log.w("LanviJenny", "Deterministic reply failed", error)
        }
    }

    private fun sendSms(context: Context, number: String, text: String) {
        if (context.checkSelfPermission(android.Manifest.permission.SEND_SMS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val manager = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) context.getSystemService(SmsManager::class.java) else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        } ?: return
        val parts = manager.divideMessage(text)
        if (parts.size <= 1) manager.sendTextMessage(number, null, text, null, null)
        else manager.sendMultipartTextMessage(number, null, parts, null, null)
    }

    private fun sendEmergencyAcknowledgement(context: Context, number: String, prefs: android.content.SharedPreferences) {
        if (context.checkSelfPermission(android.Manifest.permission.SEND_SMS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val key = "emergency_ack_${JennyRuntimePolicy.normalize(number)}"
        val now = System.currentTimeMillis()
        if (now - prefs.getLong(key, 0L) < 60 * 1000L) return
        val message = "Hi, I'm ${JennyRuntimePolicy.assistantName(JennyRuntimePolicy.read(context))}, Mayank's AI personal assistant. I've notified Mayank with an emergency alert. If someone is in immediate danger, please contact local emergency services too. Thank you."
        try {
            sendSms(context, number, message)
            prefs.edit().putLong(key, now).apply()
        } catch (error: Exception) {
            Log.w("LanviJenny", "Emergency confirmation acknowledgment failed", error)
        }
    }

    private fun notifyMayank(context: Context, sender: String, body: String, urgent: Boolean) {
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val channelId = if (urgent) "lanvi_jenny_important" else "lanvi_jenny_message_flags"
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            val importance = if (urgent) android.app.NotificationManager.IMPORTANCE_HIGH else android.app.NotificationManager.IMPORTANCE_DEFAULT
            manager.createNotificationChannel(android.app.NotificationChannel(channelId, if (urgent) "Jenny important messages" else "Jenny message flags", importance).apply {
                description = "Local alerts for saved-contact messages that may need Mayank's attention."
                lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
            })
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = launch?.let {
            android.app.PendingIntent.getActivity(
                context,
                (sender + body).hashCode(),
                it,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (android.os.Build.VERSION.SDK_INT >= 26) android.app.Notification.Builder(context, channelId) else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(if (urgent) "Jenny: important message for Mayank" else "Jenny saved a message")
            .setContentText(body.take(220))
            .setCategory(if (urgent) android.app.Notification.CATEGORY_MESSAGE else android.app.Notification.CATEGORY_STATUS)
            .setPriority(if (urgent) android.app.Notification.PRIORITY_HIGH else android.app.Notification.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .apply { if (pending != null) setContentIntent(pending) }
            .build()
        manager.notify((sender + body).hashCode(), notification)
    }

    private fun notifyEmergency(context: Context, sender: String, body: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val channelId = "lanvi_jenny_emergency"
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            val channel = android.app.NotificationChannel(channelId, "Jenny emergency alerts", android.app.NotificationManager.IMPORTANCE_HIGH)
            channel.description = "Urgent messages from saved contacts"
            channel.lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            manager.createNotificationChannel(channel)
        }
        val intent = android.content.Intent(context, JennyEmergencyActivity::class.java)
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra("sender", sender)
            .putExtra("message", body)
        val pending = android.app.PendingIntent.getActivity(
            context,
            621,
            intent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = if (android.os.Build.VERSION.SDK_INT >= 26) {
            android.app.Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
        }
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("Jenny: urgent message for Mayank")
            .setContentText("Urgent message from $sender. Tap to open emergency protocol.")
            .setCategory(android.app.Notification.CATEGORY_ALARM)
            .setPriority(android.app.Notification.PRIORITY_MAX)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setFullScreenIntent(pending, true)
            .build()
        manager.notify(621, notification)
    }

    companion object {
        private val EXECUTOR = Executors.newSingleThreadExecutor()
    }
}
