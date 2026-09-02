package info.epidemica.proximity

import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class EpidemicaProximityPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "info.epidemica.proximity/methods")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "info.epidemica.proximity/events")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        // The service keeps sensing; detections accumulate in the buffer until Dart returns.
        ProximityEvents.detach()
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) =
        ProximityEvents.attach(sink)

    override fun onCancel(arguments: Any?) = ProximityEvents.detach()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "stop" -> {
                context.stopService(Intent(context, ProximityService::class.java))
                result.success(null)
            }
            "isRunning" -> result.success(ProximityService.isRunning())
            "isRadioEnabled" -> result.success(isRadioEnabled())
            "observerDeviceClass" -> result.success("android")
            "missingPlatformRequirements" -> result.success(missingPlatformRequirements())
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val pseudonym = call.argument<String>("pseudonym")
        val serviceUuid = call.argument<String>("service_uuid")
        if (pseudonym == null || serviceUuid == null) {
            result.error("invalid_config", "pseudonym and service_uuid are required", null)
            return
        }

        val missing = missingPlatformRequirements()
        if (missing.isNotEmpty()) {
            // Refusing loudly beats starting a service that will never see anything.
            result.error("missing_platform_requirements", missing.joinToString("; "), missing)
            return
        }

        @Suppress("UNCHECKED_CAST")
        val notification = call.argument<Map<String, Any?>>("notification") ?: emptyMap()
        val intent = Intent(context, ProximityService::class.java)
            .putExtra(ProximityService.EXTRA_PSEUDONYM, pseudonym)
            .putExtra(ProximityService.EXTRA_SERVICE_UUID, serviceUuid)
            .putExtra(ProximityService.EXTRA_TITLE, notification["title"] as? String)
            .putExtra(ProximityService.EXTRA_BODY, notification["body"] as? String)
            .putExtra(ProximityService.EXTRA_CHANNEL_NAME, notification["channel_name"] as? String)
            .putExtra(
                ProximityService.EXTRA_CHANNEL_DESCRIPTION,
                notification["channel_description"] as? String,
            )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
        result.success(null)
    }

    private fun missingPlatformRequirements(): List<String> =
        ProximityService.missingPermissions(context).map { "permission not granted: $it" }

    /// Unavailable or unreadable counts as off: assuming otherwise would claim observation the
    /// device cannot provide.
    private fun isRadioEnabled(): Boolean =
        try {
            context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true
        } catch (e: SecurityException) {
            false
        }
}
