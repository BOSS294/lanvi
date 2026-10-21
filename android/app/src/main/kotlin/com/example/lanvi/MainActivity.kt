// Purpose: Flutter host and explicit MethodChannel boundary for Jenny's Android-only capabilities.
// Integration: Replace android/app/src/main/kotlin/com/example/lanvi/MainActivity.kt after backing it up.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Adds Android Keystore-backed API keys, local SMS/call history, user-confirmed actions, and role/settings requests.

package com.example.lanvi

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.example.lanvi.jenny.JennyEmergencyActivity
import com.example.lanvi.jenny.JennyKeyVault
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val channelName = "lanvi/jenny_native"
    private val runtimePrefsName = "lanvi_jenny_runtime"
    private var pendingRoleResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingSettingsResultKind: String? = null
    private val requestRoleCode = 8102
    private val requestPermissionsCode = 8103

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "saveSecret" -> {
                        val provider = call.argument<String>("provider") ?: error("Missing provider")
                        val secret = call.argument<String>("secret") ?: error("Missing secret")
                        require(secret.length <= 4096) { "Secret is unexpectedly large" }
                        JennyKeyVault(this).put(provider, secret.trim())
                        result.success(null)
                    }
                    "readSecret" -> {
                        val provider = call.argument<String>("provider") ?: error("Missing provider")
                        result.success(JennyKeyVault(this).get(provider))
                    }
                    "hasSecret" -> {
                        val provider = call.argument<String>("provider") ?: error("Missing provider")
                        result.success(JennyKeyVault(this).has(provider))
                    }
                    "deleteSecret" -> {
                        val provider = call.argument<String>("provider") ?: error("Missing provider")
                        JennyKeyVault(this).delete(provider)
                        result.success(null)
                    }
                    "saveRuntimePolicy" -> {
                        @Suppress("UNCHECKED_CAST")
                        val policy = call.argument<Map<String, Any?>>("policy") ?: emptyMap()
                        // Store only settings/rules here. API keys are kept separately in Android Keystore.
                        getSharedPreferences(runtimePrefsName, Context.MODE_PRIVATE).edit()
                            .putString("policy_json", JSONObject(policy).toString()).apply()
                        result.success(null)
                    }
                    "readRuntimePolicy" -> {
                        val raw = getSharedPreferences(runtimePrefsName, Context.MODE_PRIVATE).getString("policy_json", "{}") ?: "{}"
                        val json = JSONObject(raw)
                        val output = mutableMapOf<String, Any?>()
                        val keys = json.keys()
                        while (keys.hasNext()) {
                            val key = keys.next()
                            output[key] = jsonValueToPlatform(json.opt(key))
                        }
                        result.success(output)
                    }
                    "requestCallScreeningRole" -> requestCallScreeningRole(result)
                    "hasCallScreeningRole" -> result.success(hasCallScreeningRole())
                    "requestOverlayPermission" -> requestOverlayPermission(result)
                    "hasOverlayPermission" -> result.success(Build.VERSION.SDK_INT < 23 || android.provider.Settings.canDrawOverlays(this))
                    "hasFullScreenIntentPermission" -> result.success(hasFullScreenIntentPermission())
                    "requestFullScreenIntentPermission" -> requestFullScreenIntentPermission(result)
                    "setOverlayEnabled" -> setOverlayEnabled(call, result)
                    "openNotificationPolicySettings" -> {
                        if (Build.VERSION.SDK_INT >= 23) startActivity(Intent(android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
                        result.success(null)
                    }
                    "requestRuntimePermissions" -> requestRuntimePermissions(call, result)
                    "getContacts" -> result.success(queryContacts())
                    "getRecentSms" -> result.success(queryRecentSms())
                    "getRecentCalls" -> result.success(queryRecentCalls())
                    "openDialer" -> openDialer(call, result)
                    "openSmsComposer" -> openSmsComposer(call, result)
                    "openWhatsApp" -> openWhatsApp(call, result)
                    "sendSmsAfterConfirmation" -> sendSmsAfterConfirmation(call, result)
                    "openEmergencyDemo" -> {
                        startActivity(Intent(this, JennyEmergencyActivity::class.java)
                            .putExtra("sender", "Lanvi test")
                            .putExtra("message", "This is a test of Jenny's emergency alert. Double-tap to close."))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: SecurityException) {
                result.error("PERMISSION_REQUIRED", error.message ?: "Lanvi needs an Android permission for this action.", null)
            } catch (error: Exception) {
                result.error("JENNY_NATIVE_ERROR", error.message ?: "Jenny's Android action failed.", null)
            }
        }
    }

    private fun hasFullScreenIntentPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val manager = getSystemService(android.app.NotificationManager::class.java) ?: return false
        return manager.canUseFullScreenIntent()
    }

    private fun requestFullScreenIntentPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 34 || hasFullScreenIntentPermission()) {
            result.success(true)
            return
        }
        try {
            startActivity(Intent(android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName")))
            result.success(true)
        } catch (error: Exception) {
            result.error("FULL_SCREEN_SETTINGS_UNAVAILABLE", "Open Android app notification settings and allow full-screen alerts if the option is available.", null)
        }
    }

    private fun setOverlayEnabled(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: false
        if (enabled && Build.VERSION.SDK_INT >= 23 && !android.provider.Settings.canDrawOverlays(this)) {
            result.error("OVERLAY_PERMISSION_REQUIRED", "Grant Display over other apps before enabling Jenny's call overlay.", null)
            return
        }
        val intent = Intent(this, com.example.lanvi.jenny.JennyCallOverlayService::class.java).apply {
            action = if (enabled) com.example.lanvi.jenny.JennyCallOverlayService.ACTION_ENABLE
                     else com.example.lanvi.jenny.JennyCallOverlayService.ACTION_DISABLE
        }
        if (enabled) {
            if (Build.VERSION.SDK_INT >= 26) ContextCompat.startForegroundService(this, intent) else startService(intent)
        } else {
            startService(intent)
        }
        result.success(null)
    }

    private fun jsonValueToPlatform(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> {
            val mapped = mutableMapOf<String, Any?>()
            val keys = value.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                mapped[key] = jsonValueToPlatform(value.opt(key))
            }
            mapped
        }
        is org.json.JSONArray -> (0 until value.length()).map { index -> jsonValueToPlatform(value.opt(index)) }
        else -> value
    }

    private fun hasCallScreeningRole(): Boolean {
        if (Build.VERSION.SDK_INT < 29) return false
        val roleManager = getSystemService(RoleManager::class.java) ?: return false
        return roleManager.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING) && roleManager.isRoleHeld(RoleManager.ROLE_CALL_SCREENING)
    }

    private fun requestCallScreeningRole(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 29) {
            result.error("UNSUPPORTED", "Call screening requires Android 10 or newer.", null)
            return
        }
        val roleManager = getSystemService(RoleManager::class.java)
        if (roleManager == null || !roleManager.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING)) {
            result.error("UNAVAILABLE", "This device does not expose the call-screening role.", null)
            return
        }
        if (roleManager.isRoleHeld(RoleManager.ROLE_CALL_SCREENING)) {
            result.success(true)
            return
        }
        if (pendingRoleResult != null) {
            result.error("BUSY", "A role request is already open.", null)
            return
        }
        pendingSettingsResultKind = "call_screening"
        pendingRoleResult = result
        startActivityForResult(roleManager.createRequestRoleIntent(RoleManager.ROLE_CALL_SCREENING), requestRoleCode)
    }

    private fun requestOverlayPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 23 || android.provider.Settings.canDrawOverlays(this)) {
            result.success(true)
            return
        }
        if (pendingRoleResult != null) {
            result.error("BUSY", "Another system settings request is already open.", null)
            return
        }
        pendingSettingsResultKind = "overlay"
        pendingRoleResult = result
        startActivityForResult(Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")), requestRoleCode)
    }

    private fun requestRuntimePermissions(call: MethodCall, result: MethodChannel.Result) {
        val names = call.argument<List<String>>("permissions")?.distinct().orEmpty()
        if (names.isEmpty()) { result.success(true); return }
        val allowed = setOf(
            Manifest.permission.READ_CONTACTS, Manifest.permission.READ_SMS,
            Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS,
            Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS,
            Manifest.permission.CAMERA, Manifest.permission.MODIFY_AUDIO_SETTINGS,
        )
        if (names.any { it !in allowed }) {
            result.error("INVALID_PERMISSION", "Lanvi requested an unapproved permission name.", null)
            return
        }
        val missing = names.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) { result.success(true); return }
        if (pendingPermissionResult != null) {
            result.error("BUSY", "Another permission request is already open.", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), requestPermissionsCode)
    }

    @Deprecated("Android role/settings result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == requestRoleCode) {
            val pending = pendingRoleResult ?: return
            val kind = pendingSettingsResultKind
            pendingRoleResult = null
            pendingSettingsResultKind = null
            val granted = when (kind) {
                "overlay" -> Build.VERSION.SDK_INT < 23 || android.provider.Settings.canDrawOverlays(this)
                "call_screening" -> hasCallScreeningRole()
                else -> false
            }
            pending.success(granted)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == requestPermissionsCode) {
            val pending = pendingPermissionResult ?: return
            pendingPermissionResult = null
            pending.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        }
    }

    private fun queryContacts(): List<Map<String, Any?>> {
        checkPermission(Manifest.permission.READ_CONTACTS)
        val result = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()
        val projection = arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER)
        contentResolver.query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI, projection, null, null, "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC")?.use { cursor ->
            val nameCol = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numberCol = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (cursor.moveToNext() && result.size < 500) {
                val name = cursor.getString(nameCol).orEmpty().trim()
                val number = cursor.getString(numberCol).orEmpty().trim()
                val normalized = number.filter { it.isDigit() }
                if (name.isNotEmpty() && normalized.length >= 8 && seen.add(normalized)) {
                    result.add(mapOf("name" to name, "number" to number))
                }
            }
        }
        return result
    }

    private fun queryRecentSms(): List<Map<String, Any?>> {
        checkPermission(Manifest.permission.READ_SMS)
        val result = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE)
        contentResolver.query(Telephony.Sms.CONTENT_URI, projection, null, null, "${Telephony.Sms.DATE} DESC LIMIT 100")?.use { cursor ->
            val addressCol = cursor.getColumnIndex(Telephony.Sms.ADDRESS)
            val bodyCol = cursor.getColumnIndex(Telephony.Sms.BODY)
            val dateCol = cursor.getColumnIndex(Telephony.Sms.DATE)
            val typeCol = cursor.getColumnIndex(Telephony.Sms.TYPE)
            while (cursor.moveToNext() && result.size < 100) {
                result.add(mapOf(
                    "address" to cursor.getString(addressCol).orEmpty(),
                    "body" to cursor.getString(bodyCol).orEmpty(),
                    "date" to cursor.getLong(dateCol),
                    "type" to cursor.getInt(typeCol),
                ))
            }
        }
        return result
    }

    private fun queryRecentCalls(): List<Map<String, Any?>> {
        checkPermission(Manifest.permission.READ_CALL_LOG)
        val result = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.DATE, CallLog.Calls.TYPE, CallLog.Calls.DURATION)
        contentResolver.query(CallLog.Calls.CONTENT_URI, projection, null, null, "${CallLog.Calls.DATE} DESC")?.use { cursor ->
            val numberCol = cursor.getColumnIndex(CallLog.Calls.NUMBER)
            val nameCol = cursor.getColumnIndex(CallLog.Calls.CACHED_NAME)
            val dateCol = cursor.getColumnIndex(CallLog.Calls.DATE)
            val typeCol = cursor.getColumnIndex(CallLog.Calls.TYPE)
            val durationCol = cursor.getColumnIndex(CallLog.Calls.DURATION)
            while (cursor.moveToNext() && result.size < 100) {
                result.add(mapOf(
                    "number" to cursor.getString(numberCol).orEmpty(),
                    "name" to cursor.getString(nameCol).orEmpty(),
                    "date" to cursor.getLong(dateCol),
                    "type" to cursor.getInt(typeCol),
                    "duration" to cursor.getLong(durationCol),
                ))
            }
        }
        return result
    }

    private fun checkPermission(permission: String) {
        if (ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("Permission required: $permission")
        }
    }

    private fun openDialer(call: MethodCall, result: MethodChannel.Result) {
        val number = call.argument<String>("number")?.trim().orEmpty()
        if (number.isBlank()) { result.error("INVALID_NUMBER", "Phone number is empty.", null); return }
        startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(number)}")))
        result.success(null)
    }

    private fun openSmsComposer(call: MethodCall, result: MethodChannel.Result) {
        val number = call.argument<String>("number")?.trim().orEmpty()
        val body = call.argument<String>("body").orEmpty()
        if (number.isBlank()) { result.error("INVALID_NUMBER", "Phone number is empty.", null); return }
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${Uri.encode(number)}")).putExtra("sms_body", body)
        startActivity(intent)
        result.success(null)
    }

    private fun openWhatsApp(call: MethodCall, result: MethodChannel.Result) {
        val number = call.argument<String>("number")?.filter { it.isDigit() }.orEmpty()
        val body = call.argument<String>("body").orEmpty()
        if (number.length < 8) { result.error("INVALID_NUMBER", "A valid international phone number is required.", null); return }
        val uri = Uri.parse("https://wa.me/$number?text=${Uri.encode(body)}")
        startActivity(Intent(Intent.ACTION_VIEW, uri))
        result.success(null)
    }

    private fun sendSmsAfterConfirmation(call: MethodCall, result: MethodChannel.Result) {
        checkPermission(Manifest.permission.SEND_SMS)
        val number = call.argument<String>("number")?.trim().orEmpty()
        val body = call.argument<String>("body")?.trim().orEmpty()
        if (number.isBlank() || body.isBlank()) { result.error("INVALID_MESSAGE", "Phone number and message are required.", null); return }
        val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) getSystemService(SmsManager::class.java) else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        } ?: error("SMS service unavailable")
        val parts = manager.divideMessage(body)
        if (parts.size <= 1) manager.sendTextMessage(number, null, body, null, null)
        else manager.sendMultipartTextMessage(number, null, parts, null, null)
        result.success(null)
    }
}
