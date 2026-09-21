package com.ersingundem.larenor.inventory

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets

class InventoryShareFailure(val safeCode: String) : IllegalArgumentException(safeCode)

data class InventoryShareRequest(
    val sessionId: String,
    val interactionEpoch: Long,
    val fileName: String,
    val mimeType: String,
    val svg: String,
) {
    companion object {
        private val session = Regex("^[A-Za-z0-9._-]{8,128}$")
        private val file = Regex("^larenor-inventory-[0-9a-f]{32}\\.svg$")
        private val unsafeSvg = Regex(
            "<(?:script|!doctype|!entity)|\\bon[a-z]+\\s*=|\\b(?:href|src)\\s*=|url\\s*\\(",
            RegexOption.IGNORE_CASE,
        )

        fun parse(raw: Any?): InventoryShareRequest {
            val map = raw as? Map<*, *> ?: throw InventoryShareFailure("invalid_request")
            if (map.keys != setOf(
                    "sessionId",
                    "interactionEpoch",
                    "fileName",
                    "mimeType",
                    "svg",
                )
            ) throw InventoryShareFailure("invalid_request")
            val sessionId = map["sessionId"] as? String
                ?: throw InventoryShareFailure("invalid_request")
            val epoch = (map["interactionEpoch"] as? Number)?.toLong()
                ?: throw InventoryShareFailure("invalid_request")
            val fileName = map["fileName"] as? String
                ?: throw InventoryShareFailure("invalid_request")
            val mimeType = map["mimeType"] as? String
                ?: throw InventoryShareFailure("invalid_request")
            val svg = map["svg"] as? String
                ?: throw InventoryShareFailure("invalid_request")
            val bytes = svg.toByteArray(StandardCharsets.UTF_8)
            if (
                !session.matches(sessionId) ||
                epoch < 0 ||
                !file.matches(fileName) ||
                mimeType != "image/svg+xml" ||
                bytes.isEmpty() ||
                bytes.size > 256_000 ||
                !svg.startsWith("<svg xmlns=\"http://www.w3.org/2000/svg\"") ||
                !svg.endsWith("</svg>") ||
                unsafeSvg.containsMatchIn(svg) ||
                svg.any { it.code < 32 && it != '\n' && it != '\r' && it != '\t' }
            ) throw InventoryShareFailure("invalid_request")
            return InventoryShareRequest(sessionId, epoch, fileName, mimeType, svg)
        }
    }
}

class InventoryShareBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private var resumed = false
    private var focused = activity.hasWindowFocus()
    private var sessionId: String? = null
    private var interactionEpoch = 0L
    private var used = false
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
    }

    fun setResumed(value: Boolean) {
        if (disposed || resumed == value) return
        resumed = value
        advance()
    }

    fun windowChanged() {
        if (disposed) return
        val value = activity.hasWindowFocus()
        if (focused == value) return
        focused = value
        advance()
    }

    private fun advance() {
        if (interactionEpoch == Long.MAX_VALUE) interactionEpoch = 0
        else interactionEpoch++
        used = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            fail(result, "expired")
            return
        }
        try {
            when (call.method) {
                "activateSession" -> activate(call.arguments, result)
                "snapshot" -> result.success(snapshot())
                "shareSvg" -> share(call.arguments, result)
                else -> result.notImplemented()
            }
        } catch (failure: InventoryShareFailure) {
            fail(result, failure.safeCode)
        } catch (_: Exception) {
            fail(result, "unavailable")
        }
    }

    private fun activate(raw: Any?, result: MethodChannel.Result) {
        val map = raw as? Map<*, *> ?: throw InventoryShareFailure("invalid_request")
        if (map.keys != setOf("sessionId")) throw InventoryShareFailure("invalid_request")
        val value = map["sessionId"] as? String
            ?: throw InventoryShareFailure("invalid_request")
        if (!Regex("^[A-Za-z0-9._-]{8,128}$").matches(value)) {
            throw InventoryShareFailure("invalid_request")
        }
        sessionId = value
        advance()
        result.success(null)
    }

    private fun snapshot() = mapOf(
        "supported" to true,
        "resumed" to resumed,
        "focused" to focused,
        "interactionEpoch" to interactionEpoch,
    )

    private fun share(raw: Any?, result: MethodChannel.Result) {
        val request = InventoryShareRequest.parse(raw)
        if (
            !resumed ||
            !focused ||
            request.sessionId != sessionId ||
            request.interactionEpoch != interactionEpoch
        ) throw InventoryShareFailure("expired")
        if (used) throw InventoryShareFailure("busy")
        used = true

        val directory = File(activity.cacheDir, "inventory_exports/share")
        if (!directory.exists() && !directory.mkdirs()) {
            throw InventoryShareFailure("unavailable")
        }
        directory.listFiles()?.forEach { it.deleteRecursively() }
        val destination = File(directory, request.fileName)
        if (destination.parentFile?.canonicalFile != directory.canonicalFile) {
            throw InventoryShareFailure("invalid_request")
        }
        val temporary = File(directory, ".${request.fileName}.part")
        FileOutputStream(temporary).use { stream ->
            stream.write(request.svg.toByteArray(StandardCharsets.UTF_8))
            stream.fd.sync()
        }
        if (!temporary.renameTo(destination)) {
            temporary.delete()
            throw InventoryShareFailure("unavailable")
        }
        val authority = "${activity.packageName}.inventory_exports"
        val uri = FileProvider.getUriForFile(activity, authority, destination)
        val send = Intent(Intent.ACTION_SEND)
            .setType(request.mimeType)
            .putExtra(Intent.EXTRA_STREAM, uri)
        send.clipData = ClipData.newUri(activity.contentResolver, request.fileName, uri)
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(Intent.createChooser(send, null))
        result.success(null)
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        advance()
        sessionId = null
        channel.setMethodCallHandler(null)
    }

    private fun fail(result: MethodChannel.Result, code: String) =
        result.error(code, "Inventory export unavailable", null)

    companion object {
        const val CHANNEL = "com.ersingundem.larenor/inventory_share"
    }
}
