package com.ersingundem.larenor.game.moonlight

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files

/**
 * Routes every Moonlight credential, identity, database and preference access
 * into one authenticated Core/home/account/family namespace.
 */
class MoonlightScopedContext private constructor(
    base: Context,
    private val namespaceRoot: File,
    private val preferencePrefix: String,
) : ContextWrapper(base) {
    private val files = child("files")
    private val databases = child("databases")

    override fun getApplicationContext(): Context = this
    override fun getFilesDir(): File = files
    override fun getNoBackupFilesDir(): File = namespaceRoot

    override fun getFileStreamPath(name: String): File = checkedName(files, name)
    override fun openFileInput(name: String): FileInputStream = FileInputStream(getFileStreamPath(name))
    override fun openFileOutput(name: String, mode: Int): FileOutputStream {
        if (mode and Context.MODE_APPEND != 0) {
            return FileOutputStream(getFileStreamPath(name), true)
        }
        if (mode != Context.MODE_PRIVATE) throw SecurityException("invalid_file_mode")
        return FileOutputStream(getFileStreamPath(name), false)
    }

    override fun deleteFile(name: String): Boolean = getFileStreamPath(name).delete()
    override fun fileList(): Array<String> = files.list()?.sortedArray() ?: emptyArray()
    override fun getDatabasePath(name: String): File = checkedName(databases, name)
    override fun openOrCreateDatabase(
        name: String,
        mode: Int,
        factory: SQLiteDatabase.CursorFactory?,
    ): SQLiteDatabase = SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name), factory)

    override fun openOrCreateDatabase(
        name: String,
        mode: Int,
        factory: SQLiteDatabase.CursorFactory?,
        errorHandler: DatabaseErrorHandler?,
    ): SQLiteDatabase = SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name).path, factory, errorHandler)

    override fun deleteDatabase(name: String): Boolean = SQLiteDatabase.deleteDatabase(getDatabasePath(name))

    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
        if (!SAFE_NAME.matches(name) || mode != Context.MODE_PRIVATE) {
            throw SecurityException("invalid_preferences")
        }
        return baseContext.getSharedPreferences("$preferencePrefix.$name", Context.MODE_PRIVATE)
    }

    private fun child(name: String): File = File(namespaceRoot, name).also {
        if ((!it.isDirectory && !it.mkdirs()) || it.canonicalFile.parentFile != namespaceRoot.canonicalFile) {
            throw SecurityException("invalid_namespace")
        }
    }

    private fun checkedName(parent: File, name: String): File {
        if (!SAFE_NAME.matches(name)) throw SecurityException("invalid_file_name")
        val child = File(parent, name)
        if (child.canonicalFile.parentFile != parent.canonicalFile) {
            throw SecurityException("invalid_file_name")
        }
        return child
    }

    companion object {
        private val SAFE_NAME = Regex("^[A-Za-z0-9_.-]{1,96}$")

        fun create(base: Context, scope: MoonlightScope): MoonlightScopedContext {
            val root = File(base.noBackupFilesDir, "moonlight/${scope.storageKey}")
            if ((!root.isDirectory && !root.mkdirs()) || root.isSymbolicLink()) {
                throw SecurityException("invalid_namespace")
            }
            val moonlightRoot = File(base.noBackupFilesDir, "moonlight").canonicalFile
            if (root.canonicalFile.parentFile != moonlightRoot) throw SecurityException("invalid_namespace")
            return MoonlightScopedContext(base.applicationContext, root.canonicalFile, scope.storageKey)
        }

        private fun File.isSymbolicLink(): Boolean = Files.isSymbolicLink(toPath())
    }
}
