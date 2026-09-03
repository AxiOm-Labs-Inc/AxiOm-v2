package com.hiddify.hiddify

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * MethodChannel `com.hiddify.app/wbstream` + EventChannel
 * `com.hiddify.app/wbstream.status` for the WB Stream tunnel mode
 * (features/wbstream_tunnel on the Dart side).
 *
 * start(roomId, displayName, vp8Fps, vp8Batch, dualTrack, reliable)
 *   → starts librelay.so and returns the local SOCKS5 endpoint as
 *     {host, port, user, pass} (generated per start).
 * stop() → stops the relay process.
 * Status events: {status: starting|connecting|connected|lost|error|stopped, message: String?}
 */
class WBStreamMethodHandler : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var statusChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var controller: WBStreamRelayController? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        const val CHANNEL = "com.hiddify.app/wbstream"
        const val STATUS_CHANNEL = "com.hiddify.app/wbstream.status"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        controller = WBStreamRelayController(
            appContext = binding.applicationContext,
            nativeLibDir = binding.applicationContext.applicationInfo.nativeLibraryDir,
            onStatus = { status, message -> emitStatus(status, message) },
            onLog = { line -> android.util.Log.d(WBStreamRelayController.TAG, line) },
        )
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel!!.setMethodCallHandler(this)
        statusChannel = EventChannel(binding.binaryMessenger, STATUS_CHANNEL)
        statusChannel!!.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        statusChannel?.setStreamHandler(null)
        controller?.stop()
        controller = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val args = call.arguments as? Map<*, *>
                val roomId = args?.get("roomId") as? String
                if (roomId.isNullOrBlank()) {
                    result.error("BAD_ARGS", "roomId is required", null)
                    return
                }
                val joinJson = JSONObject().apply {
                    put("roomId", roomId)
                    put("displayName", (args["displayName"] as? String).orEmpty())
                    put("tunnelMode", "video")
                    put("vp8Fps", (args["vp8Fps"] as? Number)?.toInt() ?: 24)
                    put("vp8Batch", (args["vp8Batch"] as? Number)?.toInt() ?: 8)
                    put("dualTrack", args["dualTrack"] as? Boolean ?: false)
                    put("reliable", args["reliable"] as? Boolean ?: false)
                }.toString()
                try {
                    val socks = controller!!.start(joinJson)
                    result.success(
                        mapOf(
                            "host" to socks.host,
                            "port" to socks.port,
                            "user" to socks.user,
                            "pass" to socks.pass,
                        ),
                    )
                } catch (e: Exception) {
                    result.error("START_FAILED", e.message, null)
                }
            }

            "stop" -> {
                controller?.stop()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun emitStatus(status: String, message: String?) {
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "status" to status,
                    "message" to message,
                ),
            )
        }
    }
}
