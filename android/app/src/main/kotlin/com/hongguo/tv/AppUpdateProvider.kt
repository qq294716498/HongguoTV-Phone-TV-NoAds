package com.hongguo.tv

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

class AppUpdateProvider : ContentProvider() {
    override fun onCreate() = true

    private fun file(uri: Uri): File {
        val context = context ?: throw FileNotFoundException()
        if (uri.scheme != "content" || uri.authority != "${context.packageName}.updates" ||
            uri.path != "/pending.apk" || uri.fragment != null) throw FileNotFoundException()
        if (uri.query != null && (uri.queryParameterNames != setOf("version", "sha256") ||
                uri.getQueryParameters("version").size != 1 || uri.getQueryParameters("sha256").size != 1 ||
                uri.getQueryParameter("version")?.matches(Regex("[0-9]{1,6}")) != true ||
                uri.getQueryParameter("sha256")?.matches(Regex("[a-f0-9]{64}")) != true)) throw FileNotFoundException()
        val directory = File(context.cacheDir, "app-updates").canonicalFile
        val file = File(directory, "pending.apk")
        if (file.canonicalFile != file || !file.isFile) throw FileNotFoundException()
        return file
    }

    override fun getType(uri: Uri): String { file(uri); return "application/vnd.android.package-archive" }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val file = file(uri)
        val columns = (projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE))
            .filter { it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE }.toTypedArray()
        return MatrixCursor(columns).apply {
            addRow(Array<Any>(columns.size) { index ->
                if (columns[index] == OpenableColumns.DISPLAY_NAME) "HongguoTV-update.apk" else file.length()
            })
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("只允许读取安装包")
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}
