// Purpose: Optional user-enabled floating Jenny call card for screened cellular calls.
// Integration: Declared as specialUse foreground service; enabled only after overlay permission and user opt-in.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Shows call state plus user-confirmed call/SMS actions; never answers or records call audio.

package com.example.lanvi.jenny

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat

class JennyCallOverlayService : Service() {
    private var windowManager: WindowManager? = null
    private var overlayView: LinearLayout? = null
    private var lastNumber: String = ""
    private var lastName: String = "Unknown caller"
    private var lastDecision: String = "Incoming call screened"

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, createNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, createNotification())
        }
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISABLE -> {
                getSharedPreferences("lanvi_jenny_runtime", Context.MODE_PRIVATE).edit().putBoolean("overlayEnabled", false).apply()
                removeOverlay()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_ENABLE -> {
                getSharedPreferences("lanvi_jenny_runtime", Context.MODE_PRIVATE).edit().putBoolean("overlayEnabled", true).apply()
                return START_STICKY
            }
            ACTION_SHOW -> {
                lastNumber = intent.getStringExtra("number").orEmpty()
                lastName = intent.getStringExtra("displayName").orEmpty().ifBlank { "Incoming caller" }
                lastDecision = intent.getStringExtra("decision").orEmpty().ifBlank { "Call screened by Jenny" }
                if (isEnabledAndPermitted()) showOverlay()
            }
            ACTION_DISMISS -> removeOverlay()
        }
        return START_STICKY
    }

    private fun isEnabledAndPermitted(): Boolean {
        val policy = JennyRuntimePolicy.read(this)
        val enabledInPolicy = policy.optBoolean("overlayEnabled", false)
        val enabledInPrefs = getSharedPreferences("lanvi_jenny_runtime", Context.MODE_PRIVATE).getBoolean("overlayEnabled", false)
        val permitted = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(this)
        return enabledInPolicy && enabledInPrefs && permitted
    }

    private fun showOverlay() {
        removeOverlay()
        val wm = windowManager ?: return
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(12))
            setBackgroundColor(Color.rgb(17, 61, 38))
            elevation = dp(10).toFloat()
        }
        val title = TextView(this).apply {
            text = "${JennyRuntimePolicy.assistantName(JennyRuntimePolicy.read(this)).uppercase()} · CALL ASSISTANT"
            textSize = 11f
            letterSpacing = .12f
            setTextColor(Color.rgb(174, 226, 190))
            typeface = Typeface.DEFAULT_BOLD
        }
        val name = TextView(this).apply {
            text = lastName
            textSize = 18f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(7), 0, dp(3))
        }
        val status = TextView(this).apply {
            text = "$lastDecision\n${lastNumber.ifBlank { "Caller ID not available" }}"
            textSize = 12f
            setTextColor(Color.rgb(225, 238, 228))
            setPadding(0, 0, 0, dp(10))
        }
        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        val dial = Button(this).apply {
            text = "Open phone"
            setOnClickListener {
                removeOverlay()
                val i = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(lastNumber)}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(i)
            }
        }
        val reply = Button(this).apply {
            text = "Reply SMS"
            setOnClickListener {
                removeOverlay()
                val body = JennyRuntimePolicy.renderAssistantName(JennyRuntimePolicy.read(this), "Hi, this is Jenny, Mayank's AI personal assistant. Mayank may be unavailable right now. Please leave a message.")
                val i = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${Uri.encode(lastNumber)}"))
                    .putExtra("sms_body", body)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(i)
            }
        }
        val close = Button(this).apply {
            text = "Dismiss"
            setOnClickListener { removeOverlay() }
        }
        buttons.addView(dial, LinearLayout.LayoutParams(0, dp(44), 1f))
        buttons.addView(reply, LinearLayout.LayoutParams(0, dp(44), 1f))
        buttons.addView(close, LinearLayout.LayoutParams(0, dp(44), 1f))
        root.addView(title)
        root.addView(name)
        root.addView(status)
        root.addView(buttons)

        @Suppress("DEPRECATION")
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                   else WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            minOf(dp(380), resources.displayMetrics.widthPixels - dp(24)),
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = dp(64)
        }
        try {
            wm.addView(root, params)
            overlayView = root
        } catch (_: Exception) {
            overlayView = null
        }
    }

    private fun removeOverlay() {
        val view = overlayView ?: return
        try { windowManager?.removeView(view) } catch (_: Exception) { }
        overlayView = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Jenny call overlay", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Persistent notification while the optional Jenny call overlay is enabled."
        })
    }

    private fun createNotification(): Notification {
        val openApp = packageManager.getLaunchIntentForPackage(packageName)
        val pending = openApp?.let {
            PendingIntent.getActivity(this, 6101, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle("Jenny call overlay is enabled")
            .setContentText("Call actions open the system dialer or a message draft for confirmation.")
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setContentIntent(pending)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        removeOverlay()
        super.onDestroy()
    }

    companion object {
        const val ACTION_ENABLE = "com.example.lanvi.jenny.OVERLAY_ENABLE"
        const val ACTION_DISABLE = "com.example.lanvi.jenny.OVERLAY_DISABLE"
        const val ACTION_SHOW = "com.example.lanvi.jenny.OVERLAY_SHOW"
        const val ACTION_DISMISS = "com.example.lanvi.jenny.OVERLAY_DISMISS"
        private const val CHANNEL_ID = "lanvi_jenny_overlay"
        private const val NOTIFICATION_ID = 6101
    }
}
