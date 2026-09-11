package app.axiom

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.OutputStreamWriter
import java.net.Inet4Address
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Controls the librelay.so process (whitelist-bypass relay, MIT) running in
 * `axiom-tunnel` mode: spawns it from nativeLibraryDir, feeds the
 * JOIN command over stdin, parses STATUS/RESOLVE lines from stdout.
 *
 * Adapted from TelemostRelayController (same protocol, WB Stream room).
 * Status strings emitted to Flutter: starting/connecting/connected/lost/
 * error(message)/stopped.
 */
class TunnelRelayController(
    private val appContext: Context,
    private val nativeLibDir: String,
    private val onStatus: (status: String, message: String?) -> Unit,
    private val onLog: (String) -> Unit,
) {
    data class SocksParams(val host: String, val port: Int, val user: String, val pass: String)

    private var process: Process? = null
    private var thread: Thread? = null
    private var stdinWriter: BufferedWriter? = null
    private val pendingCommands = mutableListOf<String>()

    // Held for the whole tunnel lifetime: the VP8 relay needs continuous CPU
    // (60fps encode) and an awake radio, otherwise screen-off / vendor power
    // management suspends the tunnel within minutes.
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    @Volatile
    var isRunning = false
        private set

    /** Starts the relay and queues the JOIN command. Returns the local SOCKS5 endpoint. */
    fun start(joinJson: String): SocksParams {
        stop()
        val params = SocksParams(
            host = "127.0.0.1",
            port = freePort(),
            user = "u" + UUID.randomUUID().toString().replace("-", "").take(12),
            pass = UUID.randomUUID().toString().replace("-", "").take(16),
        )
        val signalingPort = freePort()
        isRunning = true
        acquireLocks()

        val relayBin = File(nativeLibDir, "librelay.so")
        if (!relayBin.exists()) {
            isRunning = false
            onStatus("error", "librelay.so not bundled")
            return params
        }

        thread = Thread {
            try {
                val processBuilder = ProcessBuilder(
                    relayBin.absolutePath,
                    "--mode", "axiom-tunnel",
                    "--ws-port", "$signalingPort",
                    "--socks-host", params.host,
                    "--socks-port", "${params.port}",
                    "--socks-user", params.user,
                    "--socks-pass", params.pass,
                )
                processBuilder.redirectErrorStream(true)
                val proc = processBuilder.start()
                synchronized(this) {
                    process = proc
                    stdinWriter = BufferedWriter(OutputStreamWriter(proc.outputStream))
                    pendingCommands.forEach { writeStdin(it) }
                    pendingCommands.clear()
                }
                writeStdin("JOIN:$joinJson")
                onLog("tunnel relay started (signaling :$signalingPort, socks5 ${params.host}:${params.port})")

                proc.inputStream.bufferedReader().forEachLine { line ->
                    when {
                        line.startsWith("RESOLVE:") -> resolveAndReply(line.removePrefix("RESOLVE:"))
                        line.startsWith("STATUS:CONFIG:") -> onStatus("config", line.removePrefix("STATUS:CONFIG:"))
                        line.startsWith("STATUS:") -> handleStatus(line.removePrefix("STATUS:"))
                        else -> {
                            Log.d(TAG, line)
                            onLog(line)
                        }
                    }
                }
                proc.waitFor()
                Log.d(TAG, "tunnel relay exited: ${proc.exitValue()}")
                if (isRunning) {
                    isRunning = false
                    onStatus("error", "процесс relay завершился (код ${proc.exitValue()})")
                }
            } catch (e: Exception) {
                if (isRunning) {
                    Log.e(TAG, "tunnel relay error", e)
                    isRunning = false
                    onStatus("error", e.message ?: "relay error")
                }
            }
        }.also { it.start() }
        return params
    }

    private fun resolveAndReply(hostname: String) {
        try {
            val all = InetAddress.getAllByName(hostname)
            val address = all.firstOrNull { it is Inet4Address } ?: all.first()
            writeStdin(address.hostAddress ?: "")
        } catch (e: Exception) {
            Log.e(TAG, "DNS resolve failed for $hostname", e)
            writeStdin("")
        }
    }

    private fun handleStatus(status: String) {
        Log.d(TAG, "status: $status")
        when {
            status == "READY" -> onStatus("starting", null)
            status == "CONNECTING" || status == "RECONNECTING" -> onStatus("connecting", null)
            status == "TUNNEL_CONNECTED" -> onStatus("connected", null)
            status == "TUNNEL_LOST" -> onStatus("lost", null)
            status.startsWith("ERROR:") -> onStatus("error", status.removePrefix("ERROR:"))
        }
    }

    @Synchronized
    fun stop() {
        val wasRunning = isRunning
        isRunning = false
        releaseLocks()
        try { stdinWriter?.close() } catch (_: Exception) {}
        stdinWriter = null
        val activeProcess = process
        process = null
        activeProcess?.destroy()
        if (activeProcess != null) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    if (!activeProcess.waitFor(1500, TimeUnit.MILLISECONDS)) {
                        activeProcess.destroyForcibly()
                        activeProcess.waitFor(500, TimeUnit.MILLISECONDS)
                    }
                } else {
                    activeProcess.waitFor()
                }
            } catch (_: Exception) {
            }
        }
        val activeThread = thread
        activeThread?.interrupt()
        if (activeThread != null && activeThread !== Thread.currentThread()) {
            try { activeThread.join(500) } catch (_: Exception) {}
        }
        thread = null
        if (wasRunning) onStatus("stopped", null)
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        try {
            val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "axiom:tunnel")
                .apply { acquire() }
        } catch (e: Exception) {
            Log.w(TAG, "wake lock acquire failed", e)
        }
        try {
            val wm = appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "axiom:tunnel")
                .apply { acquire() }
        } catch (e: Exception) {
            Log.w(TAG, "wifi lock acquire failed", e)
        }
    }

    private fun releaseLocks() {
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wakeLock = null
        try { wifiLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wifiLock = null
    }

    @Synchronized
    private fun writeStdin(line: String) {
        val writer = stdinWriter
        if (writer == null) {
            pendingCommands.add(line)
            return
        }
        try {
            writer.write(line)
            writer.newLine()
            writer.flush()
        } catch (e: Exception) {
            Log.e(TAG, "writeStdin error: ${e.message}")
        }
    }

    private fun freePort(): Int = ServerSocket(0).use { it.localPort }

    companion object {
        const val TAG = "A/TunnelRelay"
    }
}
