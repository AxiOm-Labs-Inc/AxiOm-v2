package com.hiddify.hiddify

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * MethodChannel `com.hiddify.app/telemost` + EventChannel
 * `com.hiddify.app/telemost.status` for the Telemost tunnel mode
 * (features/telemost_tunnel on the Dart side).
 *
 * start(joinLink, displayName, vp8Fps, vp8Batch, dualTrack, reliable)
 *   → starts librelay.so and returns the local SOCKS5 endpoint as
 *     {host, port, user, pass} (generated per start).
 * stop() → stops the relay process.
 * Status events: {status: starting|connecting|connected|lost|error|captcha|stopped, message: String?}
 */
class TelemostMethodHandler : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var statusChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var controller: TelemostRelayController? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        const val CHANNEL = "com.hiddify.app/telemost"
        const val STATUS_CHANNEL = "com.hiddify.app/telemost.status"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        controller = TelemostRelayController(
            appContext = binding.applicationContext,
            nativeLibDir = binding.applicationContext.applicationInfo.nativeLibraryDir,
            onStatus = { status, message -> emitStatus(status, message) },
            onLog = { line -> android.util.Log.d(TelemostRelayController.TAG, line) },
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
                val joinLink = args?.get("joinLink") as? String
                if (joinLink.isNullOrBlank()) {
                    result.error("BAD_ARGS", "joinLink is required", null)
                    return
                }
                val joinJson = JSONObject().apply {
                    put("joinLink", joinLink)
                    put("displayName", (args["displayName"] as? String).orEmpty())
                    put("vp8Fps", (args["vp8Fps"] as? Number)?.toInt() ?: 24)
                    put("vp8Batch", (args["vp8Batch"] as? Number)?.toInt() ?: 8)
                    put("dualTrack", args["dualTrack"] as? Boolean ?: true)
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
