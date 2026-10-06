package dev.plop.plop

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Receives "Share to plop" from other apps and hands the files or text to
/// Dart over the plop/share channel.
class MainActivity : FlutterActivity() {
  private var channel: MethodChannel? = null
  private var initial: Map<String, Any>? = null
  private var initialReady = false
  private var waiting: MethodChannel.Result? = null

  override fun configureFlutterEngine(engine: FlutterEngine) {
    super.configureFlutterEngine(engine)
    // A fresh process: shares from a previous run are gone from the shelf.
    File(cacheDir, "plop-in").deleteRecursively()
    channel = MethodChannel(engine.dartExecutor.binaryMessenger, "plop/share").apply {
      setMethodCallHandler { call, result ->
        if (call.method != "initial") return@setMethodCallHandler result.notImplemented()
        if (initialReady) {
          result.success(initial)
          initial = null
        } else {
          waiting = result
        }
      }
    }
    val launch = intent
    Thread {
      val shared = take(launch)
      runOnUiThread {
        initialReady = true
        val w = waiting
        if (w != null) {
          w.success(shared)
          waiting = null
        } else {
          initial = shared
        }
      }
    }.start()
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    Thread {
      val shared = take(intent) ?: return@Thread
      runOnUiThread { channel?.invokeMethod("shared", shared) }
    }.start()
  }

  /// Copies shared streams into the cache (big videos can take a while, so
  /// this runs off the UI thread) and returns their paths, or the shared text.
  private fun take(i: Intent?): Map<String, Any>? {
    if (i == null || (i.action != Intent.ACTION_SEND && i.action != Intent.ACTION_SEND_MULTIPLE)) {
      return null
    }
    val dir = File(cacheDir, "plop-in/${System.nanoTime()}").apply { mkdirs() }
    val paths = streams(i).mapNotNull { uri ->
      runCatching {
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
          ?.use { if (it.moveToFirst()) it.getString(0) else null }
          ?: uri.lastPathSegment ?: "file"
        val file = File(dir, name.replace('/', '_'))
        contentResolver.openInputStream(uri)!!.use { input ->
          file.outputStream().use { input.copyTo(it) }
        }
        file.path
      }.getOrNull()
    }
    val text = if (paths.isEmpty()) i.getStringExtra(Intent.EXTRA_TEXT) ?: "" else ""
    return mapOf("paths" to paths, "text" to text)
  }

  @Suppress("DEPRECATION")
  private fun streams(i: Intent): List<Uri> = if (Build.VERSION.SDK_INT >= 33) {
    if (i.action == Intent.ACTION_SEND) {
      listOfNotNull(i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
    } else {
      i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
    }
  } else {
    if (i.action == Intent.ACTION_SEND) {
      listOfNotNull(i.getParcelableExtra(Intent.EXTRA_STREAM))
    } else {
      i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
    }
  }
}
