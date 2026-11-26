package us.lastra.chit

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var shareChannel: MethodChannel? = null

    /** Shares received and copied, waiting for Dart to take them. */
    private val shares = ArrayDeque<Map<String, Any?>>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chit/system_colors").setMethodCallHandler { call, result ->
            when (call.method) {
                "scheme" -> result.success(systemScheme())
                else -> result.notImplemented()
            }
        }
        // whether the background catch-up is exempt from battery
        // optimization, and asking for it (the system's own dialog)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chit/power").setMethodCallHandler { call, result ->
            val power = getSystemService(PowerManager::class.java)
            when (call.method) {
                "exempt" -> result.success(power.isIgnoringBatteryOptimizations(packageName))
                "ask" -> {
                    @Suppress("BatteryLife")
                    startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Dart pulls shares when it is ready (a cold start would otherwise
        // race it); a ping says there is something to take.
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chit/share").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> {
                        result.success(shares.toList())
                        shares.clear()
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        cleanShareCache()
        // a share relaunched from Recents, or after the process was
        // restored, was handled the first time
        val fromHistory = intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromHistory) receive(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
    }

    /** A share into chit: its text and subject, and its files copied into
     *  the cache (off the main thread), queued for Dart. */
    private fun receive(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            streamOf(intent)?.let { uris.add(it) }
        } else {
            streamsOf(intent)?.let { uris.addAll(it) }
        }
        intent.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { if (it !in uris) uris.add(it) }
        }
        Thread {
            val files = mutableListOf<Map<String, Any?>>()
            val tooBig = mutableListOf<String>()
            for (uri in uris) {
                // only content the sending app grants; a file:// path could
                // point at this app's own data
                if (uri.scheme != "content") continue
                val copied = copy(uri)
                when {
                    copied == null -> continue
                    copied.second -> tooBig.add(copied.first.name)
                    else -> files.add(mapOf("path" to copied.first.path, "name" to copied.first.name, "size" to copied.first.length()))
                }
            }
            val share = mapOf("text" to text, "subject" to subject, "files" to files, "tooBig" to tooBig)
            runOnUiThread {
                shares.addLast(share)
                shareChannel?.invokeMethod("available", null)
            }
        }.start()
        // handled: a configuration change must not see it again
        intent.action = Intent.ACTION_MAIN
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streamsOf(intent: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)

    /** Copies [uri] into cache/share/<uuid>/<name>. The file, and whether it
     *  was over the attachment limit (then deleted). Null when unreadable. */
    private fun copy(uri: Uri): Pair<File, Boolean>? {
        var name: String? = null
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) name = c.getString(0)
        }
        if (name.isNullOrBlank()) {
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(contentResolver.getType(uri) ?: "")
            name = if (ext != null) "Shared.$ext" else "Shared file"
        }
        val safe = name!!.replace(Regex("[/\\\\\u0000]"), "_").let { if (it == "." || it == "..") "Shared file" else it }
        val dir = File(cacheDir, "share/${UUID.randomUUID()}").apply { mkdirs() }
        val dest = File(dir, safe)
        return try {
            var total = 0L
            var over = false
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { out ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_ATTACHMENT) {
                            over = true
                            break
                        }
                        out.write(buf, 0, n)
                    }
                }
            } ?: return null
            if (over) dest.delete()
            Pair(dest, over)
        } catch (e: Exception) {
            dir.deleteRecursively()
            null
        }
    }

    /** Share copies the app never took (or kept) are gone after a day. */
    private fun cleanShareCache() {
        val root = File(cacheDir, "share")
        val dayAgo = System.currentTimeMillis() - 24 * 60 * 60 * 1000
        root.listFiles()?.filter { it.lastModified() < dayAgo }?.forEach { it.deleteRecursively() }
    }

    /**
     * The system's own Material color scheme (Android 14+ publishes every
     * role as a resource, light and dark), so the app wears exactly the
     * colors the rest of the phone does. Null before Android 14, where the
     * app falls back to the wallpaper's tonal palettes.
     */
    private fun systemScheme(): Map<String, Map<String, Int>>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
        fun c(id: Int) = resources.getColor(id, theme)
        val r = android.R.color::class.java
        fun role(name: String): Int = c(r.getField(name).getInt(null))
        val roles = listOf(
            "primary", "on_primary", "primary_container", "on_primary_container",
            "secondary", "on_secondary", "secondary_container", "on_secondary_container",
            "tertiary", "on_tertiary", "tertiary_container", "on_tertiary_container",
            "error", "on_error", "error_container", "on_error_container",
            "surface", "on_surface", "surface_variant", "on_surface_variant",
            "surface_dim", "surface_bright",
            "surface_container_lowest", "surface_container_low", "surface_container",
            "surface_container_high", "surface_container_highest",
            "outline", "outline_variant",
        )
        val fixed = listOf(
            "primary_fixed", "primary_fixed_dim", "on_primary_fixed", "on_primary_fixed_variant",
            "secondary_fixed", "secondary_fixed_dim", "on_secondary_fixed", "on_secondary_fixed_variant",
            "tertiary_fixed", "tertiary_fixed_dim", "on_tertiary_fixed", "on_tertiary_fixed_variant",
        )
        fun mode(suffix: String) =
            roles.associateWith { role("system_${it}_$suffix") } + fixed.associateWith { role("system_$it") }
        return mapOf("light" to mode("light"), "dark" to mode("dark"))
    }

    companion object {
        /** The server's per-file limit (protocol.MaxAttachmentSize). */
        const val MAX_ATTACHMENT = 250L shl 20
    }
}
