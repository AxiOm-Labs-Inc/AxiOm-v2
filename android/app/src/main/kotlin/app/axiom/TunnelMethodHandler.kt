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
    private val sinkFn: (String, String?) -> Unit = { status, message -> emitStatus(status, message) }

    companion object {
        const val CHANNEL = "app.axiom/tunnel"
        const val STATUS_CHANNEL = "app.axiom/tunnel.status"

        // Relay принадлежит процессу, как и ядро (BoxService), а не экрану.
        // Раньше он жил в плагине Flutter-движка и останавливался вместе с ним:
        // смахнул приложение из недавних — relay убит, а ядро работает дальше
        // без выхода, и новый экран показывает его как VPN без интернета.
        @Volatile
        private var shared: TunnelRelayController? = null

        /** Статусы идут в экран, который сейчас подключён; нет экрана — null. */
        @Volatile
        private var sink: ((String, String?) -> Unit)? = null

        private fun controller(context: android.content.Context): TunnelRelayController =
            shared ?: synchronized(this) {
                shared ?: TunnelRelayController(
                    appContext = context,
                    nativeLibDir = context.applicationInfo.nativeLibraryDir,
                    onStatus = { status, message ->
                        val current = sink
                        if (current != null) {
                            current(status, message)
                        } else if (status == "error") {
                            // Relay умер, пока экрана нет: некому выключить
                            // Телемост, и ядро осталось бы «включённым» без
                            // выхода в интернет.
                            app.axiom.bg.BoxService.stop()
                        }
                    },
                    onLog = { line -> android.util.Log.d(TunnelRelayController.TAG, line) },
                ).also { shared = it }
            }

        /** До этого момента остановка ядра — перезапуск самим Телемостом. */
        @Volatile
        private var keepRelayUntil = 0L

        /**
         * Ядро остановилось — relay без него не нужен. Гасим здесь, а не ждём
         * приложение: без экрана его нет, а свёрнутое не слушает ядро до
         * возврата, и relay держал бы wake lock до следующего открытия.
         * Свои перезапуски ядра Телемост заранее объявляет через keepOnCoreStop.
         */
        fun onCoreStopped() {
            if (System.currentTimeMillis() < keepRelayUntil) return
            shared?.stop()
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        controller = controller(binding.applicationContext)
        sink = sinkFn
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
        // Relay не останавливаем: экран закрыли, Телемост продолжает работать.
        if (sink === sinkFn) sink = null
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

            "keepOnCoreStop" -> {
                keepRelayUntil = System.currentTimeMillis() + 15_000
                result.success(true)
            }

            // Работающий relay, оставшийся от прежнего экрана: приложение
            // подхватывает его вместо того, чтобы считать ядро чужим.
            "state" -> {
                val c = controller
                val socks = c?.socks
                result.success(
                    mapOf(
                        "running" to (c?.isRunning == true),
                        "status" to c?.lastStatus,
                        "config" to c?.lastConfig,
                        "host" to socks?.host,
                        "port" to socks?.port,
                        "user" to socks?.user,
                        "pass" to socks?.pass,
                    ),
                )
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
