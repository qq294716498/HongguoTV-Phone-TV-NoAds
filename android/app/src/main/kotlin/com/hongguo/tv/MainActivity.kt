package com.hongguo.tv

import io.flutter.embedding.android.FlutterActivity
import android.app.UiModeManager
import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.os.Build
import android.os.Bundle
import android.os.BatteryManager
import android.os.PowerManager
import android.os.SystemClock
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.net.ConnectivityManager
import android.net.Uri
import android.media.AudioManager
import kotlin.math.roundToInt
import android.util.Rational
import android.view.InputDevice
import android.view.KeyEvent
import android.view.WindowManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var appUpdateBridge: AppUpdateBridge? = null
    private var headroomReadAt = 0L
    private var thermalHeadroom: Double? = null
    private var deviceChannel: MethodChannel? = null
    private var navigationChannel: MethodChannel? = null
    private var televisionNavigationEnabled = false
    private val televisionBackKey = TelevisionBackKey()
    private var televisionMode = false
    private var televisionPlaybackActive = false
    private var activityResumed = false
    private var playbackScreenOn = false
    private var brightnessBeforeFullscreen: Float? = null
    private var fullscreenBrightness: Float? = null

    private fun applyPlaybackScreenOn() {
        val pictureInPicture = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode
        if (playbackScreenOn && activityResumed && !pictureInPicture) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun readWindowBrightness(): Float {
        val current = window.attributes.screenBrightness
        if (current.isFinite() && current >= 0f) return current.coerceIn(0.01f, 1f)
        return runCatching {
            (Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255f)
                .coerceIn(0.01f, 1f)
        }.getOrDefault(0.5f)
    }

    private fun applyFullscreenBrightness() {
        val previous = brightnessBeforeFullscreen ?: return
        val pictureInPicture = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode
        val attributes = window.attributes
        attributes.screenBrightness = if (activityResumed && !pictureInPicture && !televisionMode) {
            fullscreenBrightness ?: previous
        } else previous
        window.attributes = attributes
    }

    private fun setFullscreenBrightness(enabled: Boolean) {
        if (enabled && !televisionMode) {
            if (brightnessBeforeFullscreen == null) {
                val initial = readWindowBrightness()
                brightnessBeforeFullscreen = window.attributes.screenBrightness
                fullscreenBrightness = initial
            }
            applyFullscreenBrightness()
        } else {
            brightnessBeforeFullscreen?.let { previous ->
                val attributes = window.attributes
                attributes.screenBrightness = previous
                window.attributes = attributes
            }
            brightnessBeforeFullscreen = null
            fullscreenBrightness = null
        }
    }

    private fun forwardTelevisionBack(): Boolean {
        if (!televisionPlaybackActive || deviceChannel == null ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode)) {
            return false
        }
        deviceChannel?.invokeMethod("televisionBackPressed", null)
        return true
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val playbackBack = televisionPlaybackActive && deviceChannel != null
        val navigationBack = televisionNavigationEnabled && navigationChannel != null
        if ((playbackBack || navigationBack) &&
            (event.keyCode == KeyEvent.KEYCODE_BACK || event.keyCode == KeyEvent.KEYCODE_ESCAPE) &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.N || !isInPictureInPictureMode)) {
            val forward = televisionBackKey.shouldForward(event.keyCode, event.action, event.repeatCount, event.isCanceled)
            if (forward && event.action == KeyEvent.ACTION_UP && !event.isCanceled) {
                if (playbackBack) forwardTelevisionBack() else navigationChannel?.invokeMethod("back", null)
            }
            return true
        }
        televisionBackKey.reset()
        return super.dispatchKeyEvent(event)
    }

    @Suppress("DEPRECATION")
    private fun isTelevisionDevice(): Boolean {
        val configuration = resources.configuration
        val mode = (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType
            ?: (configuration.uiMode and Configuration.UI_MODE_TYPE_MASK)
        if (mode == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK_ONLY) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION) ||
            packageManager.hasSystemFeature("amazon.hardware.fire_tv")) {
            return true
        }
        if (mode == Configuration.UI_MODE_TYPE_CAR ||
            mode == Configuration.UI_MODE_TYPE_WATCH ||
            mode == Configuration.UI_MODE_TYPE_VR_HEADSET ||
            configuration.touchscreen != Configuration.TOUCHSCREEN_NOTOUCH ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_SENSOR_ACCELEROMETER) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_PC)) {
            return false
        }
        val remoteNavigation = configuration.navigation == Configuration.NAVIGATION_DPAD ||
            InputDevice.getDeviceIds().any { id ->
                val device = InputDevice.getDevice(id)
                device != null && !device.isVirtual && device.supportsSource(InputDevice.SOURCE_DPAD)
            }
        return remoteNavigation || packageManager.hasSystemFeature(PackageManager.FEATURE_LIVE_TV)
    }

    override fun setRequestedOrientation(requestedOrientation: Int) {
        super.setRequestedOrientation(
            if (televisionMode) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else requestedOrientation
        )
    }

    private fun playerBatteryStatus(): Map<String, Any>? {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
        if (!battery.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true)) return null
        val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0 || level > scale) return null
        val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val plugged = battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) > 0
        return mapOf(
            "percent" to (level.toDouble() * 100 / scale).roundToInt().coerceIn(0, 100),
            "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                (plugged && status == BatteryManager.BATTERY_STATUS_FULL))
        )
    }

    private fun playbackPower(): Map<String, Any?> {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val activity = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val now = SystemClock.elapsedRealtime()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            (headroomReadAt == 0L || now - headroomReadAt >= 10000L)) {
            headroomReadAt = now
            thermalHeadroom = runCatching {
                power?.getThermalHeadroom(0)?.toDouble()?.takeIf { it.isFinite() }
            }.getOrNull()
        }
        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            power?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
        } else 0
        return mapOf(
            "batterySaver" to (power?.isPowerSaveMode ?: false),
            "onBattery" to ((battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1) <= 0),
            "thermalStatus" to thermalStatus,
            "headroom" to thermalHeadroom,
            "lowMemory" to (activity?.isLowRamDevice ?: true),
            "gles" to (activity?.deviceConfigurationInfo?.reqGlEsVersion ?: 0)
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        televisionMode = if (savedInstanceState?.containsKey("duanju.televisionMode") == true) {
            savedInstanceState.getBoolean("duanju.televisionMode")
        } else isTelevisionDevice()
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
        if (televisionMode) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
    }

    override fun onResume() {
        super.onResume()
        activityResumed = true
        appUpdateBridge?.onResume()
        applyPlaybackScreenOn()
        applyFullscreenBrightness()
        if (televisionMode) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    }

    override fun onPause() {
        televisionBackKey.reset()
        activityResumed = false
        appUpdateBridge?.onPause()
        applyPlaybackScreenOn()
        applyFullscreenBrightness()
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("duanju.televisionMode", televisionMode)
        super.onSaveInstanceState(outState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appUpdateBridge = AppUpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        navigationChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hongguo/navigation")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method == "setEnabled") {
                        televisionNavigationEnabled = call.argument<Boolean>("enabled") == true
                        result.success(null)
                    } else {
                        result.notImplemented()
                    }
                }
            }
        deviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duanju/device")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "setPlaybackScreenOn" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_arg", "缺少播放亮屏状态", null)
                            } else {
                                playbackScreenOn = enabled
                                applyPlaybackScreenOn()
                                result.success(null)
                            }
                        }
                        "setTelevisionPlaybackActive" -> {
                            televisionPlaybackActive = call.argument<Boolean>("active") == true
                            result.success(null)
                        }
                        "deviceInfo" -> {
                            val version = packageManager.getPackageInfo(packageName, 0).versionName
                            result.success(mapOf("television" to isTelevisionDevice(), "version" to version))
                        }
                        "setTelevisionMode" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_display_mode", "缺少电视模式状态", null)
                            } else {
                                val changed = televisionMode != enabled
                                televisionMode = enabled
                                if (enabled) setFullscreenBrightness(false)
                                if (enabled || changed) {
                                    requestedOrientation = if (enabled) {
                                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                    } else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                                }
                                result.success(null)
                            }
                        }
                        "batteryStatus" -> result.success(runCatching { playerBatteryStatus() }.getOrNull())
                        "playbackPower" -> result.success(runCatching { playbackPower() }.getOrNull())
                        "systemProxy" -> {
                            val connection = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                            val proxy = connection.defaultProxy
                            val host = proxy?.host.orEmpty()
                            val address = if (host.isNotEmpty() && (proxy?.port ?: 0) > 0) {
                                "http://${if (host.contains(':')) "[$host]" else host}:${proxy!!.port}"
                            } else ""
                            result.success(mapOf(
                                "http" to address,
                                "https" to address,
                                "bypass" to (proxy?.exclusionList?.toList() ?: emptyList<String>()),
                                "pac" to (proxy != null && proxy.pacFileUrl != Uri.EMPTY)
                            ))
                        }
                        "pictureInPictureStatus" -> result.success(pictureInPictureStatus())
                        "enterPictureInPicture" -> {
                            val width = call.argument<Int>("width") ?: 16
                            val height = call.argument<Int>("height") ?: 9
                            result.success(enterPlayerPictureInPicture(
                                width,
                                height,
                                call.argument<Int>("left"),
                                call.argument<Int>("top"),
                                call.argument<Int>("right"),
                                call.argument<Int>("bottom")
                            ))
                        }
                        "getMediaVolume" -> {
                            val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            result.success(if (maximum > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maximum else 0.0)
                        }
                        "setMediaVolume" -> {
                            val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            val value = call.argument<Double>("volume")
                            if (value == null || !value.isFinite()) {
                                result.error("invalid_arg", "缺少音量数值", null)
                            } else if (audio.isVolumeFixed) {
                                result.error("volume_fixed", "当前音频设备使用固定音量", null)
                            } else {
                                try {
                                    val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                                    val target = (value.coerceIn(0.0, 1.0) * maximum).roundToInt()
                                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                                    result.success(if (maximum > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maximum else 0.0)
                                } catch (error: Exception) {
                                    result.error("volume_unavailable", "系统音量无法调整", null)
                                }
                            }
                        }
                        "setFullscreenBrightness" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_arg", "缺少全屏亮度状态", null)
                            } else {
                                setFullscreenBrightness(enabled)
                                result.success(true)
                            }
                        }
                        "getBrightness" -> result.success(readWindowBrightness().toDouble())
                        "setBrightness" -> {
                            val value = call.argument<Double>("brightness")?.toFloat()
                            if (value == null || !value.isFinite()) {
                                result.error("invalid_arg", "缺少有效亮度数值", null)
                            } else if (brightnessBeforeFullscreen == null || !activityResumed ||
                                televisionMode || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode)) {
                                result.success(false)
                            } else {
                                fullscreenBrightness = value.coerceIn(0.01f, 1.0f)
                                applyFullscreenBrightness()
                                result.success(true)
                            }
                        }
                        "resetBrightness" -> {
                            setFullscreenBrightness(false)
                            result.success(true)
                        }
                        "openProjectPage" -> {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds")))
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("no_browser", "未找到可用浏览器", null)
                            }
                        }
                        "openExternalPlayer" -> {
                            val url = call.argument<String>("url")
                            val title = call.argument<String>("title") ?: "短剧"
                            if (!url.isNullOrEmpty()) {
                                try {
                                    val intent = Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(Uri.parse(url), "video/*")
                                        putExtra("title", title)
                                        putExtra("return_result", true)
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    startActivity(intent)
                                    result.success(true)
                                } catch (e: Exception) {
                                    result.error("no_player", "未找到外部播放器: ${e.message}", null)
                                }
                            } else {
                                result.error("invalid_url", "播放地址为空", null)
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    private fun pictureInPictureSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun pictureInPictureStatus(): Map<String, Any> {
        return mapOf(
            "supported" to pictureInPictureSupported(),
            "active" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode)
        )
    }

    private fun enterPlayerPictureInPicture(
        width: Int,
        height: Int,
        left: Int?,
        top: Int?,
        right: Int?,
        bottom: Int?
    ): Map<String, Any> {
        if (!pictureInPictureSupported()) return pictureInPictureStatus()
        val safeWidth = width.coerceIn(1, 10000)
        val safeHeight = height.coerceIn(1, 10000)
        return runCatching {
            val builder = PictureInPictureParams.Builder()
            builder.setAspectRatio(Rational(safeWidth, safeHeight))
            if (left != null && top != null && right != null && bottom != null &&
                right > left && bottom > top) {
                builder.setSourceRectHint(Rect(left, top, right, bottom))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(true)
            }
            val entered = enterPictureInPictureMode(builder.build())
            pictureInPictureStatus() + ("requested" to entered)
        }.getOrElse { pictureInPictureStatus() }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        applyPlaybackScreenOn()
        applyFullscreenBrightness()
        deviceChannel?.invokeMethod(
            "pictureInPictureChanged",
            mapOf("active" to isInPictureInPictureMode)
        )
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (appUpdateBridge?.onActivityResult(requestCode, resultCode) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        appUpdateBridge?.close()
        appUpdateBridge = null
        playbackScreenOn = false
        applyPlaybackScreenOn()
        setFullscreenBrightness(false)
        televisionPlaybackActive = false
        navigationChannel?.setMethodCallHandler(null)
        navigationChannel = null
        televisionNavigationEnabled = false
        televisionBackKey.reset()
        deviceChannel?.setMethodCallHandler(null)
        deviceChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
