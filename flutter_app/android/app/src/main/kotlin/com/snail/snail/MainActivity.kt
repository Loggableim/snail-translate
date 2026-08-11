package com.snail.snail

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.snail.audio.SnailAudioPlugin
import android.content.Intent
import android.content.pm.PackageManager

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (flutterEngine.plugins.has(SnailAudioPlugin::class.java)) return
        flutterEngine.plugins.add(SnailAudioPlugin())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.snail.app_share/method").setMethodCallHandler { call, result ->
            when (call.method) {
                "apkInfo" -> {
                    try {
                        val info = applicationContext.applicationInfo
                        val packageInfo = packageManager.getPackageInfo(packageName, 0)
                        result.success(mapOf("path" to info.sourceDir, "version" to packageInfo.versionName))
                    } catch (error: Exception) {
                        result.error("APK_UNAVAILABLE", error.message, null)
                    }
                }
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val title = call.argument<String>("title") ?: "Snail"
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                        putExtra(Intent.EXTRA_TITLE, title)
                    }
                    startActivity(Intent.createChooser(intent, title))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
