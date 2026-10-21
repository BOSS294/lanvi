// Purpose: Read deterministic, offline call/SMS automation rules mirrored from Flutter.
// Integration: JennyCallScreeningService, JennySmsReceiver and JennyPhoneStateReceiver.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Central policy parser with safe defaults that do not reject unknown callers.

package com.example.lanvi.jenny

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

internal object JennyRuntimePolicy {
    private const val PREFS = "lanvi_jenny_runtime"
    private const val POLICY_KEY = "policy_json"

    fun read(context: Context): JSONObject {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(POLICY_KEY, "{}") ?: "{}"
        return try { JSONObject(raw) } catch (_: Exception) { JSONObject() }
    }

    fun text(policy: JSONObject, key: String, fallback: String = ""): String =
        policy.optString(key, fallback).takeIf { it.isNotBlank() } ?: fallback

    fun bool(policy: JSONObject, key: String, fallback: Boolean = false): Boolean = policy.optBoolean(key, fallback)

    fun assistantName(policy: JSONObject): String = text(policy, "assistantName", "Jenny").take(40).ifBlank { "Jenny" }

    fun renderAssistantName(policy: JSONObject, message: String): String {
        val name = assistantName(policy)
        return message.replace(Regex("Jenny", RegexOption.IGNORE_CASE), name)
    }

    fun stringList(policy: JSONObject, key: String): List<String> {
        val value = policy.optJSONArray(key) ?: JSONArray()
        return (0 until value.length()).mapNotNull { index -> value.optString(index, "").takeIf { it.isNotBlank() } }
    }

    fun normalize(number: String): String = number.filter { it.isDigit() }.trimStart('0')

    // Empty caller IDs are not treated as blocklisted by themselves. The separate
    // blockUnknownCallers setting controls how unidentified calls are handled.
    fun isBlocked(policy: JSONObject, number: String): Boolean {
        val normalized = normalize(number)
        if (normalized.isEmpty()) return false
        return stringList(policy, "blockedNumbers").any { normalize(it) == normalized }
    }

    fun isPriority(policy: JSONObject, number: String): Boolean {
        val normalized = normalize(number)
        return stringList(policy, "priorityNumbers").any { normalize(it) == normalized }
    }

    fun isSavedContact(context: Context, number: String): Boolean {
        if (number.isBlank()) return false
        return try {
            val uri = android.net.Uri.withAppendedPath(
                android.provider.ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                android.net.Uri.encode(number),
            )
            context.contentResolver.query(
                uri,
                arrayOf(android.provider.ContactsContract.PhoneLookup._ID),
                null,
                null,
                null,
            )?.use { it.moveToFirst() } ?: false
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    fun isLikelyAutomatedOrSpam(sender: String, body: String): Boolean {
        val digits = sender.filter { it.isDigit() }
        if (digits.length < 8 || sender.any { it.isLetter() }) return true
        val lower = body.lowercase()
        val patterns = listOf(
            Regex("\\botp\\b|one[- ]time password|verification code|do not share", RegexOption.IGNORE_CASE),
            Regex("bank|upi|transaction|credited|debited|loan offer|unsubscribe|promo code|discount|subscription", RegexOption.IGNORE_CASE),
            Regex("https?://|www\\.", RegexOption.IGNORE_CASE),
        )
        return patterns.any { it.containsMatchIn(lower) }
    }

    fun isEmergency(body: String): Boolean = Regex(
        "\\b(emergency|urgent|accident|hospital|danger|help me|need help|critical)\\b|आपातकाल|इमरजेंसी|दुर्घटना|अस्पताल|मदद चाहिए|खतरा",
        RegexOption.IGNORE_CASE,
    ).containsMatchIn(body)

    fun isEmergencyConfirmation(body: String): Boolean = Regex(
        "^\\s*(yes|yes please|yes emergency|emergency yes|confirm emergency|urgent yes|help now|हाँ|हां|हाँ इमरजेंसी|हां इमरजेंसी)\\s*[.!]*$",
        RegexOption.IGNORE_CASE,
    ).matches(body.trim())
}
