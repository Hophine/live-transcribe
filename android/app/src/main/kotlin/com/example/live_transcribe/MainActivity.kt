package com.example.live_transcribe

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Reports the Bluetooth headset state to Dart, asks for the one permission
// that unlocks headset audio, and keeps the screen on while transcribing.
//
// The speech_to_text plugin already routes the mic to a Bluetooth headset over
// HFP, but only when BLUETOOTH_CONNECT was granted before it initialises. The
// plugin asks for that permission only alongside RECORD_AUDIO, so once the mic
// has been granted it never asks again and headset routing stays off for good.
// This class requests it on its own, and reports which headset is connected and
// whether the SCO link is actually carrying audio.
class MainActivity : FlutterActivity() {

    private val channelName = "live_transcribe/device"
    private val permissionRequestCode = 4711

    private var channel: MethodChannel? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var headset: BluetoothHeadset? = null
    private var receiver: BroadcastReceiver? = null
    private var tts: TtsBridge? = null

    // True once the headset mic is carrying audio, not merely paired.
    private var scoActive = false

    private val needsRuntimePermission: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    private fun hasPermission(): Boolean {
        if (!needsRuntimePermission) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.BLUETOOTH_CONNECT,
        ) == PackageManager.PERMISSION_GRANTED
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val methodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = methodChannel

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(hasPermission())
                "requestPermission" -> requestPermission(result)
                "state" -> result.success(currentState())
                "keepAwake" -> {
                    keepAwake(call.arguments as? Boolean ?: false)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        tts = TtsBridge(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        openHeadsetProxy()
        registerStateReceiver()
    }

    // A dark screen can suspend the recogniser, which would end a long
    // transcription the user never asked to stop.
    private fun keepAwake(on: Boolean) {
        runOnUiThread {
            if (on) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(true)
            return
        }
        // Only one request can be outstanding. Answer any earlier one so the
        // Dart side is never left waiting on a future that will not complete.
        pendingPermission?.success(false)
        pendingPermission = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            permissionRequestCode,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
        if (granted) openHeadsetProxy()
        notifyDart()
    }

    // The HFP profile proxy is the only way to list connected headsets. Bonded
    // devices would include everything ever paired, connected or not.
    private fun openHeadsetProxy() {
        if (!hasPermission() || headset != null) return
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return
        if (!adapter.isEnabled) return
        adapter.getProfileProxy(
            this,
            object : BluetoothProfile.ServiceListener {
                override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                    if (profile != BluetoothProfile.HEADSET) return
                    headset = proxy as BluetoothHeadset
                    notifyDart()
                }

                override fun onServiceDisconnected(profile: Int) {
                    if (profile != BluetoothProfile.HEADSET) return
                    headset = null
                    notifyDart()
                }
            },
            BluetoothProfile.HEADSET,
        )
    }

    private fun registerStateReceiver() {
        if (receiver != null) return
        val handler = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED) {
                    val state = intent.getIntExtra(
                        AudioManager.EXTRA_SCO_AUDIO_STATE,
                        AudioManager.SCO_AUDIO_STATE_ERROR,
                    )
                    scoActive = state == AudioManager.SCO_AUDIO_STATE_CONNECTED
                }
                notifyDart()
            }
        }
        receiver = handler
        val filter = IntentFilter().apply {
            addAction(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
            addAction(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED)
            addAction(BluetoothHeadset.ACTION_AUDIO_STATE_CHANGED)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        ContextCompat.registerReceiver(
            this,
            handler,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    // Name of the connected headset, or null when there is none. Reading it
    // needs BLUETOOTH_CONNECT, so it stays null until that is granted.
    private fun headsetName(): String? {
        val devices = try {
            if (!hasPermission()) null else headset?.connectedDevices
        } catch (_: SecurityException) {
            null
        } ?: return null
        val device = devices.firstOrNull() ?: return null
        return try {
            device.name ?: device.address
        } catch (_: SecurityException) {
            null
        }
    }

    private fun currentState(): Map<String, Any?> {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        return mapOf(
            "permission" to hasPermission(),
            "adapterOn" to (adapter?.isEnabled ?: false),
            "headset" to headsetName(),
            "scoActive" to scoActive,
        )
    }

    private fun notifyDart() {
        runOnUiThread {
            channel?.invokeMethod("stateChanged", currentState())
        }
    }

    override fun onDestroy() {
        tts?.release()
        tts = null
        receiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Already unregistered; nothing to undo.
            }
        }
        receiver = null
        headset?.let {
            BluetoothAdapter.getDefaultAdapter()
                ?.closeProfileProxy(BluetoothProfile.HEADSET, it)
        }
        headset = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }
}
