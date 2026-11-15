package dev.zeroplayer.zero_player

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodCall

/** A small, non-focusable overlay. The user must grant Android's overlay access. */
internal class MusicLyricsOverlay(private val activity: Activity) {
    private val manager = activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var container: LinearLayout? = null
    private var title: TextView? = null
    private var lyric: TextView? = null
    private var status: TextView? = null

    fun hasPermission(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
        Settings.canDrawOverlays(activity)

    fun openPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || hasPermission()) return
        activity.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${activity.packageName}")))
    }

    fun update(call: MethodCall): Boolean {
        if (!hasPermission()) {
            hide()
            return false
        }
        if (container == null) show()
        title?.text = call.argument<String>("title")?.take(100).orEmpty()
        lyric?.text = call.argument<String>("lyric")?.take(300).orEmpty()
        status?.text = call.argument<String>("status")?.take(80).orEmpty()
        return container != null
    }

    private fun show() {
        val panel = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(10), dp(16), dp(10))
            background = GradientDrawable().apply {
                setColor(0xE8202330.toInt())
                cornerRadius = dp(18).toFloat()
                setStroke(dp(1), 0x667E90B4)
            }
        }
        title = label(13, 0xFFB9C8E6.toInt(), false).also(panel::addView)
        lyric = label(19, Color.WHITE, true).also(panel::addView)
        status = label(12, 0xFFAAB8D1.toInt(), false).also(panel::addView)
        val params = WindowManager.LayoutParams(
            dp(320).coerceAtMost(activity.resources.displayMetrics.widthPixels - dp(16)),
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL; y = dp(72) }
        panel.setOnTouchListener(object : android.view.View.OnTouchListener {
            private var startY = 0
            private var touchY = 0f
            override fun onTouch(view: android.view.View, event: MotionEvent): Boolean {
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        startY = params.y
                        touchY = event.rawY
                        return true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        params.y = (startY + (event.rawY - touchY).toInt()).coerceAtLeast(0)
                        try { manager.updateViewLayout(panel, params) } catch (_: Exception) { }
                        return true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> return true
                }
                return false
            }
        })
        try {
            manager.addView(panel, params)
            container = panel
        } catch (_: Exception) {
            title = null; lyric = null; status = null
        }
    }

    fun hide() {
        container?.let {
            try { manager.removeView(it) } catch (_: Exception) { }
        }
        container = null; title = null; lyric = null; status = null
    }

    private fun label(size: Int, color: Int, bold: Boolean) = TextView(activity).apply {
        textSize = size.toFloat()
        setTextColor(color)
        maxLines = 2
        gravity = Gravity.CENTER
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun dp(value: Int) = (value * activity.resources.displayMetrics.density).toInt()
}
