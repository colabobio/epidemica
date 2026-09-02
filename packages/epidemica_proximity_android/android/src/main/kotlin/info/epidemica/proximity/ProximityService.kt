package info.epidemica.proximity

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.heraldprox.herald.sensor.DefaultSensorDelegate
import io.heraldprox.herald.sensor.SensorArray
import io.heraldprox.herald.sensor.ble.BLESensorConfiguration
import io.heraldprox.herald.sensor.data.SensorLoggerLevel
import io.heraldprox.herald.sensor.datatype.PayloadData
import io.heraldprox.herald.sensor.datatype.Proximity
import io.heraldprox.herald.sensor.datatype.SensorType
import io.heraldprox.herald.sensor.datatype.TargetIdentifier
import io.heraldprox.herald.sensor.datatype.TimeInterval
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

/**
 * Runs Herald in a foreground service for as long as the study is sensing.
 *
 * A foreground service is not optional on modern Android: without one, scanning stops within
 * minutes of the screen locking, and it does so silently.
 */
class ProximityService : Service() {

    companion object {
        private const val TAG = "EpidemicaProximity"
        private const val NOTIFICATION_ID = 0x4550
        const val CHANNEL_ID = "info.epidemica.proximity"

        const val EXTRA_PSEUDONYM = "pseudonym"
        const val EXTRA_SERVICE_UUID = "service_uuid"
        const val EXTRA_TITLE = "notification_title"
        const val EXTRA_BODY = "notification_body"
        const val EXTRA_CHANNEL_NAME = "notification_channel_name"
        const val EXTRA_CHANNEL_DESCRIPTION = "notification_channel_description"

        private val instance = AtomicReference<ProximityService?>()

        fun isRunning(): Boolean = instance.get()?.sensorArray != null

        /** Permissions this module needs that the host app has not been granted. */
        fun missingPermissions(context: Context): List<String> {
            val required = mutableListOf<String>()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                required += Manifest.permission.BLUETOOTH_SCAN
                required += Manifest.permission.BLUETOOTH_ADVERTISE
                required += Manifest.permission.BLUETOOTH_CONNECT
            } else {
                // Pre-Android 12 the platform had no way to scan without location.
                required += Manifest.permission.ACCESS_FINE_LOCATION
            }
            return required.filter {
                ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
            }
        }
    }

    private var sensorArray: SensorArray? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance.set(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val pseudonym = intent?.getStringExtra(EXTRA_PSEUDONYM)
        val serviceUuid = intent?.getStringExtra(EXTRA_SERVICE_UUID)
        if (pseudonym == null || serviceUuid == null) {
            Log.w(TAG, "Started without a pseudonym or service UUID; stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        if (!goToForeground(intent)) return START_NOT_STICKY
        startSensing(pseudonym, serviceUuid)

        // START_STICKY so the system restarts sensing after killing us for memory. The restart
        // arrives with a null intent, which is why an unconfigured start stops rather than guesses.
        return START_STICKY
    }

    override fun onDestroy() {
        stopSensing()
        instance.compareAndSet(this, null)
        super.onDestroy()
    }

    private fun goToForeground(intent: Intent): Boolean {
        if (missingPermissions(this).isNotEmpty()) {
            Log.w(TAG, "Missing Bluetooth permissions; stopping")
            stopSelf()
            return false
        }

        val channelName = intent.getStringExtra(EXTRA_CHANNEL_NAME) ?: "Contact recording"
        val channelDescription = intent.getStringExtra(EXTRA_CHANNEL_DESCRIPTION) ?: ""
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW)
        channel.description = channelDescription
        manager.createNotificationChannel(channel)

        val notification = buildNotification(intent)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Could not enter the foreground", e)
            stopSelf()
            false
        }
    }

    private fun buildNotification(intent: Intent): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(intent.getStringExtra(EXTRA_TITLE) ?: "Recording contacts")
            .setContentText(intent.getStringExtra(EXTRA_BODY) ?: "")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

    private fun startSensing(pseudonym: String, serviceUuid: String) {
        // A system-restarted service can arrive with the previous session's sensor still held.
        stopSensing()

        BLESensorConfiguration.payloadDataUpdateTimeInterval = TimeInterval.minutes(1)
        BLESensorConfiguration.customServiceUUID = UUID.fromString(serviceUuid)
        BLESensorConfiguration.customServiceDetectionEnabled = true
        BLESensorConfiguration.customServiceAdvertisingEnabled = true
        // Study scoping: with the standard Herald service off, devices in other studies — and other
        // Herald apps entirely — are neither seen nor visible.
        BLESensorConfiguration.standardHeraldServiceDetectionEnabled = false
        BLESensorConfiguration.standardHeraldServiceAdvertisingEnabled = false
        BLESensorConfiguration.logLevel = SensorLoggerLevel.off

        val array = SensorArray(applicationContext, EpidemicaPayloadSupplier(pseudonym))
        array.add(Delegate())
        try {
            array.start()
            sensorArray = array
            ProximityEvents.emit(mapOf("type" to "started"))
        } catch (e: Exception) {
            Log.e(TAG, "Herald failed to start", e)
            stopSelf()
        }
    }

    private fun stopSensing() {
        sensorArray?.let {
            try {
                it.stop()
            } catch (e: Exception) {
                Log.w(TAG, "Herald failed to stop cleanly", e)
            }
        }
        sensorArray = null
    }

    /**
     * Only the callback that carries both a payload and a signal strength is used. The
     * payload-only and proximity-only callbacks cannot be turned into a detection without
     * guessing at the other half.
     */
    private inner class Delegate : DefaultSensorDelegate() {
        override fun sensor(
            sensor: SensorType,
            didMeasure: Proximity,
            fromTarget: TargetIdentifier,
            withPayload: PayloadData,
        ) {
            val rssi = didMeasure.value ?: return
            val decoded = ProximityPayload.decode(withPayload.value) ?: return
            ProximityEvents.emit(
                mapOf(
                    "type" to "detection",
                    "peer" to decoded.pseudonym,
                    "rssi" to rssi,
                    // Stamped here, not on arrival in Dart: delivery can be delayed and the error
                    // would land on exactly the long background encounters that matter most.
                    "observed_at_ms" to System.currentTimeMillis(),
                    "peer_device_class" to decoded.deviceClass,
                ),
            )
        }
    }
}
