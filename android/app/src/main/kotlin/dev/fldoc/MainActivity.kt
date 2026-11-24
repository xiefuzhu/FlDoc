package dev.fldoc

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private data class LibraryRequest(
        val code: Int,
        val reply: MethodChannel.Result,
        val onSelect: (Uri) -> Any,
    )

    private var libraryRequest: LibraryRequest? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.fldoc/libraries")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importFolder" -> pickLibraryDocument(
                        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), IMPORT_FOLDER, result, ::importFolder,
                    )
                    "savePackage" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name")
                        if (path == null || name == null) {
                            result.error("INVALID_PACKAGE", "无法读取资料包", null)
                        } else {
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/zip"
                                putExtra(Intent.EXTRA_TITLE, name)
                            }
                            pickLibraryDocument(intent, SAVE_PACKAGE, result) { uri ->
                                val output = contentResolver.openOutputStream(uri)
                                    ?: throw IOException("无法写入所选位置")
                                output.use { stream -> File(path).inputStream().use { it.copyTo(stream) } }
                                true
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickLibraryDocument(
        intent: Intent,
        code: Int,
        reply: MethodChannel.Result,
        onSelect: (Uri) -> Any,
    ) {
        if (libraryRequest != null) {
            reply.error("BUSY", "正在处理文档库", null)
            return
        }
        libraryRequest = LibraryRequest(code, reply, onSelect)
        try {
            startActivityForResult(intent, code)
        } catch (error: Exception) {
            libraryRequest = null
            reply.error("PICK_FAILED", error.message, null)
        }
    }

    @Deprecated("Uses FlutterActivity's activity result bridge for the document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val request = libraryRequest ?: return
        if (requestCode != request.code) return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            libraryRequest = null
            request.reply.success(null)
            return
        }
        thread(name = "fldoc-library-transfer") {
            val transferred = runCatching { request.onSelect(uri) }
            runOnUiThread {
                libraryRequest = null
                transferred.fold(
                    onSuccess = { request.reply.success(it) },
                    onFailure = { request.reply.error("TRANSFER_FAILED", it.message, null) },
                )
            }
        }
    }

    private fun importFolder(tree: Uri): String {
        val root = File(filesDir, "imported_libraries")
        val importId = UUID.randomUUID().toString()
        val staging = File(root, ".import-$importId")
        if (!staging.mkdirs()) throw IOException("无法创建文档库目录")
        try {
            val id = DocumentsContract.getTreeDocumentId(tree)
            val source = DocumentsContract.buildDocumentUriUsingTree(tree, id)
            val sourceName = contentResolver.query(source, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null }
                ?.let(::safeName) ?: "文档库"
            val name = if (sourceName.startsWith('.')) "_$sourceName" else sourceName
            val library = File(staging, name)
            if (!library.mkdir()) throw IOException("无法创建文档库目录")
            if (!copyFolder(tree, id, library)) throw IOException("文件夹内没有 Markdown 文档")
            val destination = File(root, importId)
            if (!staging.renameTo(destination)) throw IOException("无法保存文档库")
            return destination.absolutePath
        } finally {
            if (staging.exists()) staging.deleteRecursively()
        }
    }

    private fun copyFolder(tree: Uri, id: String, destination: File): Boolean {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
        val fields = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE)
        var hasMarkdown = false
        val cursor = contentResolver.query(children, fields, null, null, null)
            ?: throw IOException("无法读取文件夹")
        cursor.use {
            while (it.moveToNext()) {
                val childId = it.getString(0)
                val name = safeName(it.getString(1))
                val child = File(destination, name)
                if (child.exists()) throw IOException("文件夹内有重名文件：$name")
                if (it.getString(2) == Document.MIME_TYPE_DIR) {
                    if (!child.mkdir()) throw IOException("无法创建文件夹：$name")
                    val childHasMarkdown = copyFolder(tree, childId, child)
                    hasMarkdown = hasMarkdown || childHasMarkdown
                } else {
                    val uri = DocumentsContract.buildDocumentUriUsingTree(tree, childId)
                    val input = contentResolver.openInputStream(uri)
                        ?: throw IOException("无法读取文件：$name")
                    input.use { stream -> child.outputStream().use { output -> stream.copyTo(output) } }
                    hasMarkdown = hasMarkdown || name.endsWith(".md", ignoreCase = true)
                }
            }
        }
        return hasMarkdown
    }

    private fun safeName(value: String): String {
        if (value.isBlank() || value == "." || value == ".." || '/' in value || '\\' in value) {
            throw IOException("无效文件名")
        }
        return value
    }

    private companion object {
        const val IMPORT_FOLDER = 4201
        const val SAVE_PACKAGE = 4202
    }
}
