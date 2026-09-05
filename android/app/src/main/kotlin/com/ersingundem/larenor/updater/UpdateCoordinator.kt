package com.ersingundem.larenor.updater

import java.io.File
import java.util.UUID

interface UpdateHost {
    fun installed(): InstalledClient
    fun foreground(): Boolean
    fun verify(file: File): ArchiveIdentity
}

class UpdateWork internal constructor(val sessionId: String, val operation: Long, val id: String,
    val release: ClientRelease, val file: File, val cancellation: UpdateCancellation)
class StagedClient internal constructor(val sessionId: String, val id: String, val release: ClientRelease, val file: File) {
    fun packet(): Map<String, Any> = mapOf("id" to id, "versionCode" to release.versionCode, "sizeBytes" to release.sizeBytes)
}

/** Session changes retire files; losing foreground cancels work without making
 * an already verified download disappear during Android's permission screen. */
class UpdateCoordinator(private val directory: File, private val host: UpdateHost) {
    private var session: String? = null
    private var epoch = 0L
    private var work: UpdateWork? = null
    private var staged: StagedClient? = null
    private var disposed = false
    init {
        File(directory, "incoming").mkdirs(); File(directory, "install").mkdirs()
        // Only this component owns these directories and filename format.
        for (child in listOf("incoming", "install")) File(directory, child).listFiles()?.forEach {
            if (it.isFile && Regex("[a-f0-9-]{36}\\.(part|apk)").matches(it.name)) it.delete()
        }
    }
    @Synchronized fun activate(id: String) {
        if (disposed || !Regex("[a-zA-Z0-9-]{16,80}").matches(id)) throw UpdateFailure("expired")
        if (session == id) return
        retire(); session = id
    }
    @Synchronized fun invalidate(id: String) { if (session == id) { retire(); session = null } }
    @Synchronized fun cancel(id: String) { if (session == id) cancelWork() }
    @Synchronized fun suspend() { cancelWork() }
    @Synchronized fun dispose() { retire(); session = null; disposed = true }
    private fun cancelWork() { epoch++; work?.cancellation?.cancel(); work = null }
    private fun retire() { cancelWork(); staged?.file?.delete(); staged = null }
    private fun requireSession(id: String) {
        if (disposed || session != id) throw UpdateFailure("expired")
        if (!host.foreground()) throw UpdateFailure("expired")
    }
    @Synchronized fun requirePermissionAction(id: String) { requireSession(id); if (work != null) throw UpdateFailure("busy") }
    @Synchronized fun beginDownload(sessionId: String, release: ClientRelease, downloadId: String = UUID.randomUUID().toString()): UpdateWork {
        requireSession(sessionId)
        if (!Regex("[a-f0-9-]{36}").matches(downloadId)) throw UpdateFailure("invalidMetadata")
        if (work != null) throw UpdateFailure("busy")
        UpdateValidation.preflight(release, host.installed())
        staged?.file?.delete(); staged = null
        val id = downloadId
        return UpdateWork(sessionId, ++epoch, id, release, File(directory, "incoming/$id.part"), UpdateCancellation()).also { work = it }
    }
    @Synchronized fun current(value: UpdateWork): Boolean = !disposed && session == value.sessionId && work === value && epoch == value.operation && !value.cancellation.isCancelled
    @Synchronized fun check(value: UpdateWork) { if (!current(value)) throw UpdateFailure("cancelled") }
    fun verify(value: UpdateWork) {
        check(value)
        UpdateValidation.archive(value.release, host.installed(), host.verify(value.file))
        check(value)
    }
    @Synchronized fun finishDownload(value: UpdateWork): StagedClient {
        check(value)
        if (!host.foreground()) throw UpdateFailure("expired")
        val target = File(directory, "install/${value.id}.apk")
        if (!value.file.renameTo(target)) throw UpdateFailure("unavailable")
        // No later write uses this name. The installer gets a read-only grant.
        if (!target.setReadOnly()) { target.delete(); throw UpdateFailure("unavailable") }
        return StagedClient(value.sessionId, value.id, value.release, target).also { staged = it; work = null }
    }
    @Synchronized fun failed(value: UpdateWork) {
        value.cancellation.cancel()
        if (value.file.parentFile?.name == "incoming") value.file.delete()
        if (work === value) work = null
    }
    @Synchronized fun beginInstall(sessionId: String, id: String): UpdateWork {
        requireSession(sessionId)
        if (work != null) throw UpdateFailure("busy")
        val value = staged?.takeIf { it.id == id && it.sessionId == sessionId } ?: throw UpdateFailure("expired")
        return UpdateWork(sessionId, ++epoch, id, value.release, value.file, UpdateCancellation()).also { work = it }
    }
    @Synchronized fun consumeInstall(value: UpdateWork): File {
        check(value); requireSession(value.sessionId)
        if (staged?.id != value.id) throw UpdateFailure("expired")
        // Consume before opening Android: repeated callbacks cannot open a
        // second installer. The granted file survives the Activity pause.
        staged = null; work = null
        return value.file
    }
}
