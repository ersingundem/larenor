package com.ersingundem.larenor.rdp

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import android.system.Os
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.text.Normalizer

internal data class RdpSafDocument(
    val uri: Uri,
    val name: String,
    val mimeType: String,
    val size: Long?,
    val flags: Int,
)

internal data class RdpSafSealedFile(
    val name: String,
    val size: Long,
    val sha256: String,
    val file: File,
)

internal sealed interface RdpSafCandidateSet {
    data object None : RdpSafCandidateSet
    data class One(val document: RdpSafDocument) : RdpSafCandidateSet
    data object Multiple : RdpSafCandidateSet
}

internal interface RdpSafDocumentsPort {
    fun snapshotToRemote(treeUri: Uri, targetDirectory: File, cancel: CancellationSignal): List<RdpSafSealedFile>
    fun inspectSaveCandidate(treeUri: Uri, name: String, cancel: CancellationSignal): RdpSafCandidateSet
    fun createForSave(treeUri: Uri, name: String, cancel: CancellationSignal): RdpSafDocument
    fun writeOnce(document: RdpSafDocument, source: RdpSafSealedFile, cancel: CancellationSignal)
    fun readback(document: RdpSafDocument, expected: RdpSafSealedFile, cancel: CancellationSignal): Boolean
}

internal fun openPrivateMirrorPart(
    value: File,
    permissions: RdpSafPrivatePermissions = RdpSafPrivatePermissions.ANDROID,
): FileOutputStream {
    val stream = FileOutputStream(value)
    return try {
        permissions.descriptor.setMode(stream.fd, RDP_SAF_PRIVATE_FILE_MODE)
        stream
    } catch (error: Exception) {
        stream.close()
        value.delete()
        throw error
    }
}

internal class RdpSafDocumentsAdapter(
    private val resolver: ContentResolver,
) : RdpSafDocumentsPort {
    override fun snapshotToRemote(
        treeUri: Uri,
        targetDirectory: File,
        cancel: CancellationSignal,
    ): List<RdpSafSealedFile> {
        requirePrivateDirectory(targetDirectory)
        val source = exactDirectory(treeUri, TO_REMOTE, cancel)
        val documents = children(treeUri, source, cancel)
        validateSet(documents)
        var total = 0L
        return documents.sortedBy { it.name }.map { document ->
            cancel.throwIfCanceled()
            val part = File(targetDirectory, ".${document.name}.part")
            val output = File(targetDirectory, document.name)
            requireSafeNewFile(part, targetDirectory)
            requireSafeNewFile(output, targetDirectory)
            val digest = MessageDigest.getInstance("SHA-256")
            var count = 0L
            try {
                resolver.openFileDescriptor(document.uri, "r", cancel)?.use { descriptor ->
                    FileInputStream(descriptor.fileDescriptor).use { input ->
                        openPrivateMirrorPart(part).use { sink ->
                            val buffer = ByteArray(BUFFER_BYTES)
                            while (true) {
                                cancel.throwIfCanceled()
                                val read = input.read(buffer)
                                if (read < 0) break
                                count = Math.addExact(count, read.toLong())
                                if (document.size != null && count > document.size || count > MAX_FILE_BYTES) reject()
                                digest.update(buffer, 0, read)
                                sink.write(buffer, 0, read)
                            }
                            buffer.fill(0)
                            sink.fd.sync()
                        }
                    }
                } ?: reject()
                if (document.size != null && count != document.size || !part.renameTo(output)) reject()
                total = Math.addExact(total, count)
                if (total > MAX_TOTAL_BYTES) reject()
                requireSafeExistingFile(output, targetDirectory)
                RdpSafSealedFile(document.name, count, digest.digest().hex(), output)
            } catch (error: Exception) {
                part.delete()
                throw error
            }
        }
    }

    override fun inspectSaveCandidate(
        treeUri: Uri,
        name: String,
        cancel: CancellationSignal,
    ): RdpSafCandidateSet {
        validateName(name)
        val destination = exactDirectory(treeUri, FROM_REMOTE, cancel)
        val children = children(treeUri, destination, cancel)
        validateSet(children)
        val matches = children.filter { it.name == name }
        return when {
            matches.isEmpty() -> RdpSafCandidateSet.None
            matches.size == 1 -> RdpSafCandidateSet.One(matches.single())
            else -> RdpSafCandidateSet.Multiple
        }
    }

    override fun createForSave(treeUri: Uri, name: String, cancel: CancellationSignal): RdpSafDocument {
        validateName(name)
        cancel.throwIfCanceled()
        val destination = exactDirectory(treeUri, FROM_REMOTE, cancel)
        if (inspectSaveCandidate(treeUri, name, cancel) !is RdpSafCandidateSet.None) reject()
        val uri = DocumentsContract.createDocument(
            resolver,
            destination.uri,
            "application/octet-stream",
            name,
        ) ?: reject()
        cancel.throwIfCanceled()
        val result = exactDocument(treeUri, uri, cancel)
        if (result.name != name || result.mimeType != "application/octet-stream" || isVirtual(result)) reject()
        val candidate = inspectSaveCandidate(treeUri, name, cancel)
        if (candidate !is RdpSafCandidateSet.One || candidate.document.uri != result.uri) reject()
        return result
    }

    /** Exactly-once dispatch. A caller must journal the document URI and WRITE_DISPATCHED first. */
    override fun writeOnce(document: RdpSafDocument, source: RdpSafSealedFile, cancel: CancellationSignal) {
        if (document.name != source.name) reject()
        cancel.throwIfCanceled()
        resolver.openFileDescriptor(document.uri, "rwt", cancel)?.use { descriptor ->
            FileInputStream(source.file).use { input ->
                FileOutputStream(descriptor.fileDescriptor).use { output ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    var count = 0L
                    while (true) {
                        cancel.throwIfCanceled()
                        val read = input.read(buffer)
                        if (read < 0) break
                        count = Math.addExact(count, read.toLong())
                        if (count > source.size) reject()
                        output.write(buffer, 0, read)
                    }
                    buffer.fill(0)
                    if (count != source.size) reject()
                    output.fd.sync()
                }
            }
        } ?: reject()
    }

    override fun readback(
        document: RdpSafDocument,
        expected: RdpSafSealedFile,
        cancel: CancellationSignal,
    ): Boolean {
        if (document.name != expected.name) return false
        val digest = MessageDigest.getInstance("SHA-256")
        var count = 0L
        resolver.openFileDescriptor(document.uri, "r", cancel)?.use { descriptor ->
            FileInputStream(descriptor.fileDescriptor).use { input ->
                val buffer = ByteArray(BUFFER_BYTES)
                while (true) {
                    cancel.throwIfCanceled()
                    val read = input.read(buffer)
                    if (read < 0) break
                    count = Math.addExact(count, read.toLong())
                    if (count > expected.size || count > MAX_FILE_BYTES) return false
                    digest.update(buffer, 0, read)
                }
                buffer.fill(0)
            }
        } ?: return false
        return count == expected.size && digest.digest().hex() == expected.sha256
    }

    private fun exactDirectory(treeUri: Uri, name: String, cancel: CancellationSignal): RdpSafDocument {
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val root = RdpSafDocument(
            DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId),
            "<root>",
            DocumentsContract.Document.MIME_TYPE_DIR,
            0,
            0,
        )
        val matches = children(treeUri, root, cancel).filter {
            it.name == name && it.mimeType == DocumentsContract.Document.MIME_TYPE_DIR && !isVirtual(it)
        }
        if (matches.size != 1) reject()
        return matches.single()
    }

    private fun exactDocument(treeUri: Uri, uri: Uri, cancel: CancellationSignal): RdpSafDocument {
        val result = resolver.query(uri, PROJECTION, null, null, null, cancel)?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            val document = cursor.document(treeUri)
            if (cursor.moveToNext()) reject()
            document
        } ?: reject()
        return result
    }

    private fun children(
        treeUri: Uri,
        parent: RdpSafDocument,
        cancel: CancellationSignal,
    ): List<RdpSafDocument> {
        cancel.throwIfCanceled()
        val parentId = DocumentsContract.getDocumentId(parent.uri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        return resolver.query(childrenUri, PROJECTION, null, null, null, cancel)?.use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    cancel.throwIfCanceled()
                    add(cursor.document(treeUri))
                    if (size > MAX_FILES) reject()
                }
            }
        } ?: reject()
    }

    private fun Cursor.document(treeUri: Uri): RdpSafDocument {
        val id = getString(getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID))
        val name = getString(getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME))
        val mime = getString(getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE))
        val sizeColumn = getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
        val size = if (isNull(sizeColumn)) null else getLong(sizeColumn)
        val flags = getInt(getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS))
        validateName(name)
        if (size != null && size !in 0..MAX_FILE_BYTES) reject()
        return RdpSafDocument(
            DocumentsContract.buildDocumentUriUsingTree(treeUri, id),
            name,
            mime,
            size,
            flags,
        )
    }

    private fun validateSet(documents: List<RdpSafDocument>) {
        if (documents.size > MAX_FILES || documents.any {
                it.mimeType == DocumentsContract.Document.MIME_TYPE_DIR || isVirtual(it)
            }
        ) reject()
        if (documents.map { Normalizer.normalize(it.name, Normalizer.Form.NFC) }.toSet().size != documents.size) reject()
        if (documents.sumOf { it.size ?: 0L } > MAX_TOTAL_BYTES) reject()
    }

    private fun isVirtual(value: RdpSafDocument) =
        value.flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0

    private fun validateName(value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size !in 1..MAX_NAME_BYTES || value in setOf(".", "..") ||
            value.any { it == '\u0000' || it == '/' || it == '\\' || it.code < 0x20 || it.code == 0x7f }
        ) reject()
    }

    private fun requirePrivateDirectory(value: File) {
        if (!value.isDirectory || java.nio.file.Files.isSymbolicLink(value.toPath())) reject()
    }

    private fun requireSafeNewFile(value: File, parent: File) {
        if (value.parentFile?.canonicalFile != parent.canonicalFile || value.exists()) reject()
    }

    private fun requireSafeExistingFile(value: File, parent: File) {
        if (value.parentFile?.canonicalFile != parent.canonicalFile || !value.isFile ||
            java.nio.file.Files.isSymbolicLink(value.toPath()) ||
            (java.nio.file.Files.getAttribute(value.toPath(), "unix:nlink") as Number).toLong() != 1L ||
            Os.stat(value.absolutePath).st_mode and 0x1ff != 0x180
        ) reject()
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun reject(): Nothing = throw IllegalStateException("saf_transfer_unavailable")

    companion object {
        const val TO_REMOTE = "ToRemote"
        const val FROM_REMOTE = "FromRemote"
        const val MAX_FILES = 32
        const val MAX_FILE_BYTES = 256L * 1024 * 1024
        const val MAX_TOTAL_BYTES = 1024L * 1024 * 1024
        const val MAX_NAME_BYTES = 255
        private const val BUFFER_BYTES = 64 * 1024
        private val PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
    }
}
