package com.ersingundem.larenor.rdp

import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.system.Os
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.security.MessageDigest

/** Test-APK DocumentsProvider used only by the owned Gateway+RDPDR acceptance case. */
class RdpOwnedSafDocumentsProvider : DocumentsProvider() {
    override fun onCreate(): Boolean = context != null

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: ROOT_COLUMNS)
        cursor.newRow().apply {
            add(DocumentsContract.Root.COLUMN_ROOT_ID, ROOT_ID)
            add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, ROOT_ID)
            add(DocumentsContract.Root.COLUMN_TITLE, "Larenor owned transfer fixture")
            add(DocumentsContract.Root.COLUMN_FLAGS,
                DocumentsContract.Root.FLAG_SUPPORTS_CREATE or DocumentsContract.Root.FLAG_LOCAL_ONLY)
            add(DocumentsContract.Root.COLUMN_MIME_TYPES, "application/octet-stream")
            add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, MAX_TOTAL_BYTES)
        }
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_COLUMNS)
        addDocument(cursor, documentId, fileFor(documentId))
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_COLUMNS)
        val parent = fileFor(parentDocumentId)
        requirePrivateDirectory(parent)
        parent.listFiles()?.sortedBy(File::getName)?.forEach { child ->
            addDocument(cursor, documentId(child), child)
        }
        return cursor
    }

    override fun getDocumentType(documentId: String): String = mime(fileFor(documentId))

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        signal?.throwIfCanceled()
        val file = fileFor(documentId)
        requirePrivateFile(file)
        val flags = ParcelFileDescriptor.parseMode(mode)
        require(flags and ParcelFileDescriptor.MODE_READ_WRITE != 0 ||
            flags and ParcelFileDescriptor.MODE_READ_ONLY != 0)
        return ParcelFileDescriptor.open(file, flags)
    }

    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String,
    ): String {
        require(parentDocumentId == FROM_REMOTE_ID)
        require(mimeType == "application/octet-stream")
        validateName(displayName)
        val directory = fileFor(parentDocumentId)
        requirePrivateDirectory(directory)
        val child = File(directory, displayName)
        require(child.parentFile?.canonicalFile == directory.canonicalFile && child.createNewFile())
        Os.chmod(child.absolutePath, 0x180)
        requirePrivateFile(child)
        return documentId(child)
    }

    private fun addDocument(cursor: MatrixCursor, id: String, file: File) {
        if (file.isDirectory) requirePrivateDirectory(file) else requirePrivateFile(file)
        cursor.newRow().apply {
            add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, id)
            add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, if (id == ROOT_ID) "Larenor" else file.name)
            add(DocumentsContract.Document.COLUMN_MIME_TYPE, mime(file))
            add(DocumentsContract.Document.COLUMN_SIZE, if (file.isFile) file.length() else null)
            add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, file.lastModified())
            add(DocumentsContract.Document.COLUMN_FLAGS, if (file.isDirectory) {
                if (id == FROM_REMOTE_ID) DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE else 0
            } else {
                DocumentsContract.Document.FLAG_SUPPORTS_WRITE
            })
        }
    }

    private fun mime(file: File) = if (file.isDirectory) {
        DocumentsContract.Document.MIME_TYPE_DIR
    } else {
        "application/octet-stream"
    }

    private fun root(): File = requireNotNull(context).noBackupFilesDir
        .resolve(PRIVATE_ROOT)
        .canonicalFile

    private fun fileFor(documentId: String): File {
        require(documentId == ROOT_ID || documentId.startsWith("$ROOT_ID/"))
        val relative = documentId.removePrefix(ROOT_ID).removePrefix("/")
        require(relative.split('/').all { it.isNotEmpty() && it !in setOf(".", "..") })
        val result = if (relative.isEmpty()) root() else File(root(), relative).canonicalFile
        require(result == root() || result.toPath().startsWith(root().toPath()))
        require(!Files.isSymbolicLink(result.toPath()) && result.exists())
        return result
    }

    private fun documentId(file: File): String {
        val relative = root().toPath().relativize(file.canonicalFile.toPath()).toString()
        require(relative.isNotEmpty() && !relative.startsWith(".."))
        return "$ROOT_ID/${relative.replace(File.separatorChar, '/')}"
    }

    private fun requirePrivateDirectory(file: File) {
        require(file.isDirectory && !Files.isSymbolicLink(file.toPath()))
        require(Os.stat(file.absolutePath).st_mode and 0x1ff == 0x1c0)
    }

    private fun requirePrivateFile(file: File) {
        require(file.isFile && !Files.isSymbolicLink(file.toPath()))
        require((Files.getAttribute(file.toPath(), "unix:nlink") as Number).toLong() == 1L)
        require(Os.stat(file.absolutePath).st_mode and 0x1ff == 0x180)
    }

    private fun validateName(value: String) {
        require(value.toByteArray(Charsets.UTF_8).size in 1..255)
        require(value !in setOf(".", ".."))
        require(value.none { it == '\u0000' || it == '/' || it == '\\' || it.code < 0x20 || it.code == 0x7f })
    }

    companion object {
        const val AUTHORITY = "com.ersingundem.larenor.test.rdp_owned_saf"
        const val ROOT_ID = "root"
        const val TO_REMOTE_ID = "$ROOT_ID/ToRemote"
        const val FROM_REMOTE_ID = "$ROOT_ID/FromRemote"
        private const val PRIVATE_ROOT = "f62-owned-gateway-saf-provider-v1"
        private const val MAX_TOTAL_BYTES = 1024L * 1024 * 1024
        private val ROOT_COLUMNS = arrayOf(
            DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID,
            DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_FLAGS,
            DocumentsContract.Root.COLUMN_MIME_TYPES,
            DocumentsContract.Root.COLUMN_AVAILABLE_BYTES,
        )
        private val DOCUMENT_COLUMNS = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
        )

        fun reset(context: android.content.Context, uploadName: String, upload: ByteArray): Uri {
            validateOwnedName(uploadName)
            val root = context.noBackupFilesDir.resolve(PRIVATE_ROOT)
            if (root.exists()) root.walkBottomUp().forEach { require(it.delete()) }
            require(root.mkdir())
            val toRemote = File(root, "ToRemote").also { require(it.mkdir()) }
            File(root, "FromRemote").also { require(it.mkdir()) }
            listOf(root, toRemote, File(root, "FromRemote")).forEach { Os.chmod(it.absolutePath, 0x1c0) }
            val source = File(toRemote, uploadName)
            FileOutputStream(source).use { stream ->
                stream.write(upload)
                stream.fd.sync()
            }
            Os.chmod(source.absolutePath, 0x180)
            return DocumentsContract.buildTreeDocumentUri(AUTHORITY, ROOT_ID)
        }

        fun assertProviderReadback(
            context: android.content.Context,
            outboundName: String,
            expectedSha256: String,
        ): String {
            validateOwnedName(outboundName)
            val value = context.noBackupFilesDir.resolve(PRIVATE_ROOT)
                .resolve("FromRemote").resolve(outboundName)
            require(value.isFile && !Files.isSymbolicLink(value.toPath()))
            require((Files.getAttribute(value.toPath(), "unix:nlink") as Number).toLong() == 1L)
            require(Os.stat(value.absolutePath).st_mode and 0x1ff == 0x180)
            val digest = MessageDigest.getInstance("SHA-256").digest(value.readBytes()).hex()
            require(digest == expectedSha256)
            return digest
        }

        private fun validateOwnedName(value: String) {
            require(Regex("^(?:upload|outbound)-[0-9a-f]{16}\\.bin$").matches(value))
        }

        private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    }
}
