package us.lastra.chit

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chit/system_colors").setMethodCallHandler { call, result ->
            when (call.method) {
                "scheme" -> result.success(systemScheme())
                else -> result.notImplemented()
            }
        }
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
}
