package app.axiom

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * MethodChannel `app.axiom/tunnel` + EventChannel
 * `app.axiom/tunnel.status` for the Telemost tunnel mode
 * (features/telemost on the Dart side).
 *
 * start(displayName, vp8Fps, vp8Batch, dualTrack, reliable,
 *       tmSecret?, authMode?)
 *   → starts librelay.so and returns the local SOCKS5 endpoint as
 *     {host, port, user, pass} (generated per start).
 * stop() → stops the relay process.
 * Status events: {status: starting|connecting|connected|lost|error|stopped, message: String?}
 */
class TunnelMethodHandler : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var statusChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var controller: TunnelRelayController? = null
    private var appContext: android.content.Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        const val CHANNEL = "app.axiom/tunnel"
        const val STATUS_CHANNEL = "app.axiom/tunnel.status"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        controller = TunnelRelayController(
            appContext = binding.applicationContext,
            nativeLibDir = binding.applicationContext.applicationInfo.nativeLibraryDir,
            onStatus = { status, message -> emitStatus(status, message) },
            onLog = { line -> android.util.Log.d(TunnelRelayController.TAG, line) },
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
                // roomId, адреса Диска и ключ слота больше не приходят из
                // приложения — relay находит комнату сам. Приложение шлёт только
                // секрет, режим авторизации и параметры видео.
                val joinJson = JSONObject().apply {
                    put("displayName", (args?.get("displayName") as? String).orEmpty())
                    put("tunnelMode", "video")
                    put("vp8Fps", (args?.get("vp8Fps") as? Number)?.toInt() ?: 24)
                    put("vp8Batch", (args?.get("vp8Batch") as? Number)?.toInt() ?: 8)
                    put("dualTrack", args?.get("dualTrack") as? Boolean ?: false)
                    put("reliable", args?.get("reliable") as? Boolean ?: false)
                    // Память своей комнаты relay пишет в файл рядом с данными
                    // приложения (переехала из SharedPreferences).
                    put("statePath", java.io.File(appContext!!.filesDir, "axiom_tunnel_room.json").absolutePath)
                    // Секрет Телемоста и режим авторизации. Пусто — relay идёт
                    // без рукопожатия.
                    (args?.get("tmSecret") as? String)?.let { put("tmSecret", it) }
                    (args?.get("authMode") as? String)?.let { put("authMode", it) }
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
