package io.github.ccch1mneyyy.dsh_app.tilt

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt

/**
 * 「陀螺仪光斑偏移」（总方案 v3 第 7 步）。
 *
 * 只把这一台手机的**倾斜**交给 Dart：不再引入 Flutter 传感器包，SensorManager 直接读，
 * 约 30Hz 一拍，低通滤波后按 [-1, 1] 两轴输出（右倾 +x、前倾 +y）。Dart 侧再乘上
 * ≤ 6dp 的位移上限去推背景光斑，所以这里不做任何像素换算。
 *
 * 什么时候不送：
 * - 没有传感器（模拟器、老设备）→ `available=false`，Dart 侧就不注册。
 * - 系统省电模式 / 设备在省电 → 直接不出流（省电模式下让背景保持静止）。
 * - 前台之外也不送：Dart 侧在聊天页可见时才 `start`，离开就 `stop`，这里不自己判断生命周期。
 *
 * 一拍的频控靠 [SensorManager.registerListener] 的 33ms，不另起线程；低通滤波是
 * `filtered += alpha * (raw - filtered)`，alpha 0.18 让手抖被抹平、慢速倾斜跟得住。
 */
class TiltPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var manager: SensorManager? = null
    private var power: PowerManager? = null
    private var listening = false
    private var gravity: FloatArray? = null

    /// 两轴的低通结果，单位是「重力分量比例」。
    private val filtered = FloatArray(2)
    private var sink: EventChannel.EventSink? = null

    private val sensorListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val out = sample(event.values) ?: return
            val s = sink ?: return
            s.success(mapOf("x" to out[0].toDouble(), "y" to out[1].toDouble()))
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        manager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        MethodChannel(binding.binaryMessenger, METHOD).setMethodCallHandler(this)
        EventChannel(binding.binaryMessenger, EVENTS).setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        MethodChannel(binding.binaryMessenger, METHOD).setMethodCallHandler(null)
        EventChannel(binding.binaryMessenger, EVENTS).setStreamHandler(null)
        manager = null
        power = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(manager?.getDefaultSensor(Sensor.TYPE_GRAVITY) != null)
            "powerSaving" -> result.success(powerSaving())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (powerSaving()) {
            // 省电模式：注册了也不送，Dart 侧拿到的是空流，光斑保持静止。
            return
        }
        val m = manager ?: return
        val sensor = m.getDefaultSensor(Sensor.TYPE_GRAVITY) ?: m.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
        listening = m.registerListener(sensorListener, sensor, SAMPLE_US) || run {
            sink = null
            false
        }
        if (listening) sink?.success(mapOf("x" to 0.0, "y" to 0.0))
    }

    override fun onCancel(arguments: Any?) {
        stop()
        sink = null
    }

    private fun stop() {
        if (listening) manager?.unregisterListener(sensorListener)
        listening = false
        gravity = null
        filtered[0] = 0f
        filtered[1] = 0f
    }

    /**
     * 一拍 → 两轴。重力传感器给的是重力方向（静止时约 9.81 的模长），加速度传感器给的是
     * 重力 + 手的加速度；两种都归一到「重力分量比例」，所以同一套滤波都能用。
     * 返回 null：模长太小（手机在自由落体/剧烈甩动），这一拍丢掉，别让光斑乱跳。
     */
    private fun sample(values: FloatArray): FloatArray? {
        if (values.size < 3) return null
        val x = values[0]
        val y = values[1]
        val z = values[2]
        val norm = sqrt(x * x + y * y + z * z)
        if (norm < 4f || norm > 20f) return null
        // 右倾 / 前倾对应的两个分量，按重力方向归一。
        val targetX = (x / norm).coerceIn(-1f, 1f)
        val targetY = (y / norm).coerceIn(-1f, 1f)
        filtered[0] += ALPHA * (targetX - filtered[0])
        filtered[1] += ALPHA * (targetY - filtered[1])
        return FloatArray(2).also {
            it[0] = filtered[0]
            it[1] = filtered[1]
        }
    }

    private fun powerSaving(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        val p = power ?: return false
        return p.isPowerSaveMode || !p.isInteractive
    }

    private companion object {
        const val METHOD = "dsh/tilt"
        const val EVENTS = "dsh/tilt/events"

        /** 30Hz（33ms）。 */
        const val SAMPLE_US = 33_000
        const val ALPHA = 0.18f
    }
}
