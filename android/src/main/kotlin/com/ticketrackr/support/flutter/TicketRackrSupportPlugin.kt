package com.ticketrackr.support.flutter

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.webkit.URLUtil
import android.widget.Toast
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** A file opened in support goes to the system's downloads, with a notification to open it from, and support stays. */
class TicketRackrSupportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ticketrackr_support/files")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "download") return result.notImplemented()
        val url = call.argument<String>("url") ?: return result.error("url", "No file link.", null)
        try {
            val type = call.argument<String>("type")?.substringBefore(';')?.trim()?.takeIf { it.isNotEmpty() }
            val name = URLUtil.guessFileName(url, call.argument<String>("disposition"), type)
            val request = DownloadManager.Request(Uri.parse(url))
                .setTitle(name)
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            type?.let { request.setMimeType(it) }
            if (Build.VERSION.SDK_INT >= 29) {
                request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name)
            } else {
                // Before Android 10, Downloads needs a storage permission; the app's own folder doesn't.
                request.setDestinationInExternalFilesDir(context, Environment.DIRECTORY_DOWNLOADS, name)
            }
            (context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager).enqueue(request)
            call.argument<String>("downloading")?.let { Toast.makeText(context, it, Toast.LENGTH_SHORT).show() }
            result.success(true)
        } catch (error: Exception) {
            result.error("download", error.message, null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
