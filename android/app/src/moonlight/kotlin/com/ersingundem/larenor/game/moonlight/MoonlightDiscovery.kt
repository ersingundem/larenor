package com.ersingundem.larenor.game.moonlight

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.limelight.discovery.DiscoveryService
import com.limelight.nvstream.mdns.MdnsComputer
import com.limelight.nvstream.mdns.MdnsDiscoveryListener
import java.util.concurrent.atomic.AtomicBoolean

internal data class MoonlightDiscoveredEndpoint(
    val name: String,
    val host: String,
    val port: Int,
) {
    init {
        require(name.isNotBlank() && name.length <= 128)
        require(host.isNotBlank() && host.length <= 255)
        require(port in 1..65535)
    }
}

internal fun interface MoonlightDiscovery {
    fun discover(timeoutMillis: Long, callback: (Result<List<MoonlightDiscoveredEndpoint>>) -> Unit)
}

/** Uses upstream Moonlight's real `_nvstream._tcp` NSD/JmDNS discovery service. */
internal class MoonlightMdnsDiscovery(private val context: Context) : MoonlightDiscovery {
    private val main = Handler(Looper.getMainLooper())

    override fun discover(
        timeoutMillis: Long,
        callback: (Result<List<MoonlightDiscoveredEndpoint>>) -> Unit,
    ) {
        if (timeoutMillis !in 1_000..120_000) {
            callback(Result.failure(MoonlightRuntimeFailure("invalid_timeout")))
            return
        }
        main.post {
            val completed = AtomicBoolean(false)
            val found = linkedMapOf<String, MoonlightDiscoveredEndpoint>()
            var binder: DiscoveryService.DiscoveryBinder? = null
            lateinit var connection: ServiceConnection
            lateinit var timeoutTask: Runnable

            fun complete(result: Result<List<MoonlightDiscoveredEndpoint>>) {
                if (!completed.compareAndSet(false, true)) return
                main.removeCallbacks(timeoutTask)
                runCatching { binder?.stopDiscovery() }
                runCatching { context.unbindService(connection) }
                callback(result)
            }

            connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                    val upstream = service as? DiscoveryService.DiscoveryBinder
                        ?: return complete(Result.failure(MoonlightRuntimeFailure("provider_unavailable")))
                    binder = upstream
                    upstream.setListener(object : MdnsDiscoveryListener {
                        override fun notifyComputerAdded(computer: MdnsComputer) {
                            add(computer, found)
                        }

                        override fun notifyDiscoveryFailure(error: Exception?) {
                            complete(Result.failure(MoonlightRuntimeFailure("provider_unavailable")))
                        }
                    })
                    runCatching { upstream.getComputerSet().forEach { add(it, found) } }
                    upstream.startDiscovery(1_000)
                }

                override fun onServiceDisconnected(name: ComponentName?) {
                    complete(Result.failure(MoonlightRuntimeFailure("provider_unavailable")))
                }
            }
            timeoutTask = Runnable {
                complete(if (binder == null) {
                    Result.failure(MoonlightRuntimeFailure("provider_unavailable"))
                } else Result.success(found.values.toList()))
            }
            main.postDelayed(timeoutTask, timeoutMillis)
            val intent = Intent(context, DiscoveryService::class.java)
            if (!context.bindService(intent, connection, Context.BIND_AUTO_CREATE)) {
                complete(Result.failure(MoonlightRuntimeFailure("provider_unavailable")))
            }
        }
    }

    private fun add(
        computer: MdnsComputer,
        found: MutableMap<String, MoonlightDiscoveredEndpoint>,
    ) {
        val address = computer.localAddress ?: computer.ipv6Address ?: return
        val host = address.hostAddress ?: return
        val endpoint = runCatching {
            MoonlightDiscoveredEndpoint(computer.name, host.substringBefore('%'), computer.port)
        }.getOrNull() ?: return
        addDiscoveredEndpoint(found, endpoint, MAX_HOSTS)
    }

    companion object {
        private const val MAX_HOSTS = 64
    }
}

internal fun addDiscoveredEndpoint(
    found: MutableMap<String, MoonlightDiscoveredEndpoint>,
    endpoint: MoonlightDiscoveredEndpoint,
    limit: Int,
) {
    val key = "${endpoint.host}:${endpoint.port}"
    if (key !in found && found.size >= limit) return
    found[key] = endpoint
}
