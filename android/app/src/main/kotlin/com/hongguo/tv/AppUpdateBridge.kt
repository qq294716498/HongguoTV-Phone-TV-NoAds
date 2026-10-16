package com.hongguo.tv

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.ZipFile

class AppUpdateBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "hongguo/updates")
    private val worker = Executors.newSingleThreadExecutor()
    private var closed = false
    private var installerResult: MethodChannel.Result? = null
    private var installerUri: Uri? = null
    private val installSession = UpdateInstallSession()
    private val directory get() = File(activity.cacheDir, "app-updates")
    private val apk get() = File(directory, "pending.apk")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "installedInfo" -> background(result) { installedInfo() }
                "directory" -> background(result) {
                    directory.mkdirs()
                    directory.canonicalPath
                }
                "validate" -> background(result) { validate(call); null }
                "canInstall" -> result.success(activity.packageManager.canRequestPackageInstalls())
                "openPermission" -> {
                    try {
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}")))
                        result.success(null)
                    } catch (error: Exception) { result.error("permission_unavailable", "此设备无法打开安装权限设置", null) }
                }
                "install" -> install(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                activity.runOnUiThread { if (!closed) result.success(value) }
            } catch (error: Exception) {
                activity.runOnUiThread { if (!closed) result.error("invalid_update", error.message ?: "更新验证失败", null) }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun packageFlags() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun installed() = activity.packageManager.getPackageInfo(activity.packageName, packageFlags())

    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo) = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { digest(it.toByteArray()) }?.toSet() ?: emptySet()
    }

    private fun abis(file: File): Set<String> = ZipFile(file).use { zip ->
        zip.entries().asSequence().map { it.name }
            .filter { it.matches(Regex("lib/[^/]+/[^/]+\\.so")) }
            .map { it.split('/')[1] }.toSet()
    }

    private fun installedAbi(): String {
        val abis = abis(File(activity.applicationInfo.sourceDir))
        UpdateValidation.require(abis.size == 1, "无法确认已安装应用架构；请使用对应架构的正式安装包")
        val abi = abis.single()
        UpdateValidation.require(UpdateValidation.offset(abi) > 0 && Build.SUPPORTED_ABIS.contains(abi), "已安装架构不受支持")
        return abi
    }

    private fun installedInfo(): Map<String, Any> {
        UpdateValidation.require(BuildConfig.UPDATER_ALL_SOURCES, "当前构建不使用此更新频道")
        val info = installed()
        UpdateValidation.require(info.packageName == UpdateValidation.PACKAGE &&
            signers(info) == setOf(UpdateValidation.CERTIFICATE), "当前不是可覆盖升级的正式签名版本")
        return mapOf("version" to (info.versionName ?: "未知版本"), "code" to code(info), "abi" to installedAbi())
    }

    private fun validate(call: MethodCall) {
        UpdateValidation.require(BuildConfig.UPDATER_ALL_SOURCES, "当前构建不使用此更新频道")
        val expectedBytes = call.argument<Number>("bytes")?.toLong() ?: 0
        val expectedHash = call.argument<String>("sha256") ?: ""
        val expectedCode = call.argument<Number>("code")?.toLong() ?: 0
        val expectedVersion = call.argument<String>("version") ?: ""
        val expectedAbi = call.argument<String>("abi") ?: ""
        UpdateValidation.require(apk.canonicalFile == File(directory.canonicalFile, "pending.apk") && apk.isFile,
            "安装包不在应用专用更新目录")
        UpdateValidation.require(apk.length() == expectedBytes && expectedBytes > 0 && expectedBytes <= UpdateValidation.MAXIMUM_BYTES,
            "安装包大小不一致")
        val hash = MessageDigest.getInstance("SHA-256")
        apk.inputStream().use { stream ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        val actualHash = hash.digest().joinToString("") { "%02x".format(it) }
        UpdateValidation.verifyBytes(expectedBytes, apk.length(), expectedHash, actualHash)
        val current = installed()
        val candidate = activity.packageManager.getPackageArchiveInfo(apk.path, packageFlags())
            ?: throw IllegalArgumentException("无法解析安装包或验证签名")
        UpdateValidation.verifyVersionName(expectedVersion, candidate.versionName)
        UpdateValidation.verifyIdentity(current.packageName, candidate.packageName,
            signers(current), signers(candidate), code(current), code(candidate), expectedCode,
            installedAbi(), abis(apk), expectedAbi)
        UpdateValidation.require((candidate.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) <= Build.VERSION.SDK_INT,
            "安装包不支持当前 Android 版本")
    }

    @Suppress("DEPRECATION")
    private fun install(call: MethodCall, result: MethodChannel.Result) {
        if (installerResult != null) {
            result.error("installer_busy", "安装界面已打开", null)
            return
        }
        val preferences = activity.getSharedPreferences("updater-installer", 0)
        val requestCode = (preferences.getInt("sequence", 4820) + 1).let { if (it >= 65000) 4821 else it }
        preferences.edit().putInt("sequence", requestCode).apply()
        installSession.begin(requestCode)
        installerResult = result
        worker.execute {
            try {
                validate(call)
                activity.runOnUiThread {
                    if (closed) return@runOnUiThread
                    try {
                        UpdateValidation.require(activity.packageManager.canRequestPackageInstalls(), "未允许安装更新")
                        val uri = Uri.parse("content://${activity.packageName}.updates/pending.apk").buildUpon()
                            .appendQueryParameter("version", call.argument<Number>("code").toString())
                            .appendQueryParameter("sha256", call.argument<String>("sha256"))
                            .build()
                        installerUri = uri
                        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                            data = uri
                            clipData = ClipData.newRawUri("HongguoTV update", uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            putExtra(Intent.EXTRA_RETURN_RESULT, true)
                        }
                        if (installSession.launch(requestCode)) {
                            activity.startActivityForResult(intent, requestCode)
                        }
                    } catch (error: Exception) {
                        installerResult?.error("installer_unavailable", error.message ?: "此设备无法打开系统安装器", null)
                        installerResult = null
                        installSession.complete(requestCode)
                    }
                }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    if (!closed) installerResult?.error("invalid_update", error.message ?: "安装包验证失败", null)
                    installerResult = null
                    installSession.complete(requestCode)
                }
            }
        }
    }

    fun onPause() { installSession.pause() }

    fun onResume() {
        val requestCode = installSession.resume()
        if (requestCode == 0) return
        activity.window.decorView.postDelayed({
            if (!closed && installSession.canReturn(requestCode)) completeInstaller(requestCode, "returned")
        }, 600)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (!installSession.matches(requestCode)) return false
        completeInstaller(requestCode, if (resultCode == Activity.RESULT_CANCELED) "cancelled" else "returned")
        return true
    }

    private fun completeInstaller(requestCode: Int, value: String) {
        if (!installSession.complete(requestCode)) return
        installerResult?.success(value)
        installerResult = null
        installerUri?.let { activity.revokeUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        installerUri = null
    }

    fun close() {
        closed = true
        installerResult?.error("closed", "应用界面已关闭，可重新检查更新", null)
        installerResult = null
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

}
