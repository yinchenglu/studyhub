package __PACKAGE__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ServiceInfo
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.DisplayMetrics
import android.util.Size
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 学聚的自定义 MainActivity。四个原生能力都在这个文件里，一次注入到位。
 *
 *   1. `studyhub/display` → `physicalDpi` —— 把**面板真实物理 DPI** 交给 Dart 侧（直尺工具用）。
 *
 *      为什么要这个：
 *        直尺工具要按真实尺寸显示刻度，需要知道「1 个逻辑像素等于多少英寸」。
 *        Flutter 的 `devicePixelRatio` 只给了「逻辑像素 → 物理像素」这一半关系，
 *        另一半「物理像素 → 英寸」必须问系统要 —— 也就是 `DisplayMetrics.xdpi`。
 *        Flutter 框架没有暴露它，所以自己架一个 MethodChannel。
 *
 *      为什么不直接用 `densityDpi`：
 *        那是厂商从 240 / 320 / 420 / 480 这些档位里挑的**标称值**。
 *        真实 6.7 吋 1080x2400 的面板物理密度约 393，厂商很可能填 420，
 *        照它画出来的尺子整套偏小 6.9%，量 30 cm 差 2 cm。
 *        `xdpi / ydpi` 才是驱动上报的真实值。
 *
 *      出错一律返回 null：
 *        Dart 侧会回退到「1 英寸 = 160 逻辑像素」的默认近似。
 *        尺子略微不准可以接受，工具页崩掉不行。
 *
 *   2. `studyhub/display` → `lockOrientation` —— 把屏幕方向钉死在**当前**朝向（播放器 / 图片预览用）。
 *
 *      为什么必须在原生做：
 *        Flutter 只有 `SystemChrome.setPreferredOrientations`，它接受的是一个
 *        「允许方向的集合」，表达不了「就停在这一刻这个方向」。
 *        Dart 侧也拿不到「现在到底是左横屏还是右横屏」（`MediaQuery.orientation`
 *        只分竖 / 横）。靠加速度计自己算左右，符号约定一搞反就是画面倒转 180°。
 *        `SCREEN_ORIENTATION_LOCKED` 的官方定义就是
 *        「Screen is locked to its current rotation, whatever that is.」
 *        —— 交给系统去记，我们不需要知道，也就不会算错。API 18+。
 *
 *   3. `studyhub/display` → `followOrientation` —— 打开「跟着手机转」（v1.5.0 新增，修一个真 bug）。
 *
 *      ⚠️ 这个也必须走原生，原因和 2 是同一类问题：
 *        Flutter 的 `setPreferredOrientations([portraitUp, landscapeLeft,
 *        landscapeRight])` 在 Android 侧映射到 `SCREEN_ORIENTATION_USER`，
 *        而 `USER` 的官方定义是「用户当前的首选方向」——
 *        也就是说**用户在系统里关掉「自动旋转」之后，这个方法就不转了**。
 *        手机上绝大多数人是常年关着自动旋转的，于是视频「跟着手机横竖屏切换」
 *        看起来就跟没做一样。
 *        `SCREEN_ORIENTATION_SENSOR` 的官方说明是
 *        「即使用户锁定基于传感器的旋转，系统仍可使用传感器」，
 *        正好是我们要的语义。而且 `SENSOR` 本身就不含反向竖屏
 *        （和 Flutter 那套「竖屏 + 左右横屏」的意图一致），不用额外排除。
 *
 *      解锁不需要加方法：
 *        Dart 侧再调一次 `SystemChrome.setPreferredOrientations(...)`，
 *        会把 requestedOrientation 覆盖成 `SCREEN_ORIENTATION_USER`。
 *
 *   4. `studyhub/location`（v1.5.0 新增，指南针用）—— 走 EventChannel 持续推位置。
 *
 *      为什么不用第三方定位包：
 *        这个项目对依赖极其敏感（历史上被 win32 / mime / xml 三条链锁死过好几轮）。
 *        指南针只要「经纬度 + 海拔 + 精度」，`LocationManager` 十几行就够了，
 *        没必要为此再引一个包和它背后的权限框架。
 *
 *      为什么用 EventChannel 而不是 MethodChannel 轮询：
 *        定位是**持续变化**的东西，回调推送比分频道，Dart 侧 `StreamBuilder` 直接消费。
 *        `onListen` 里开定位、`onCancel` 里关定位 —— 页面销毁自动停，
 *        不会像轮询那样忘了关就一直啃电。
 *
 *      一次同时挂 GPS 与网络定位：
 *        GPS 精度高但要等、室内常拿不到；网络定位快但粗。
 *        两个都挂上，谁先来算谁的，室外几秒内就能收敛到 5 米级。
 *        先把手里的 `getLastKnownLocation` 推一次，界面不用空着等。
 *
 *   5. `studyhub/recorder`（v1.5.0 新增，后台录音用）—— 前台服务 + MediaRecorder。
 *
 *      ⚠️ 为什么要前台服务，不能直接在页面里录：
 *        Android 9（API 28）起，**后台应用拿不到麦克风**。
 *        没有前台服务的话，一息屏 / 一切到后台，录音会被系统掐掉 ——
 *        而「后台录音」正是这个工具存在的理由。
 *        带 `foregroundServiceType="microphone"` 的前台服务 + 常驻通知，
 *        才是唯一合规且真的能一直录的做法（Android 14 强制要求声明类型）。
 *
 *      为什么服务写成 MainActivity 的**嵌套类**：
 *        云端构建只注入这一个 .kt 文件（工作流里 `cat android_custom/MainActivity.kt
 *        > 骨架的 MainActivity.kt`）。写成嵌套类就不用改工作流去拷第二个文件。
 *        嵌套类在 Kotlin 里是 static 的，框架用反射能实例化，
 *        清单里写成 `.MainActivity$RecorderService` 即可。
 *
 *      录像走 Dart 侧的 camera 插件（前台录），不在这里做：
 *        后台录视频要 Camera2 + Surface 手写一遍，代码量大且没法在本地验证；
 *        而系统本身也限制后台访问摄像头。这里只把「后台」这件最难的事做扎实。
 */
class MainActivity : FlutterActivity() {

    private var locationSink: EventChannel.EventSink? = null
    private var locationManager: LocationManager? = null

    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            emitLocation(location)
        }

        @Deprecated("Java 接口要求实现；Android 已经不再回调它了")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

        override fun onProviderEnabled(provider: String) {}

        override fun onProviderDisabled(provider: String) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "physicalDpi" -> result.success(readPhysicalDpi())
                    "lockOrientation" -> result.success(lockCurrentOrientation())
                    "followOrientation" -> result.success(followOrientation())
                    else -> result.notImplemented()
                }
            }

        // ---- 定位（指南针用）：持续推送 ----
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOCATION_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    if (events != null) startLocation(events)
                }

                override fun onCancel(arguments: Any?) {
                    stopLocation()
                }
            })

        // ---- 后台录音：开 / 停 / 查状态 ----
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RECORDER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val path = call.argument<String>("path")
                        // 用 Any 接再自己转 Number：Dart 传过来的整数在标准编解码器里
                        // 小的是 Int、大的会变 Long，写死 argument<Int> 会在
                        // 「不限时长」传 0 以外的大数时拿到 null。
                        val maxMs = (call.argument<Any>("maxDurationMs") as? Number)?.toLong() ?: 0L
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "缺少录音文件路径", null)
                        } else {
                            try {
                                RecorderService.start(applicationContext, path, maxMs)
                                result.success(true)
                            } catch (t: Throwable) {
                                result.error("start_failed", t.message ?: "启动录音失败", null)
                            }
                        }
                    }
                    "stop" -> {
                        try {
                            RecorderService.stop(applicationContext)
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("stop_failed", t.message ?: "停止录音失败", null)
                        }
                    }
                    "status" -> {
                        val out = HashMap<String, Any?>()
                        out["running"] = RecorderService.running
                        out["elapsedMs"] = RecorderService.elapsedMs()
                        out["error"] = RecorderService.lastError
                        result.success(out)
                    }
                    else -> result.notImplemented()
                }
            }

        // ---- 后台录像：开 / 停 / 查状态（v1.6.0 新增）----
        //
        // 和上面那条录音通道长得一样，但走的是完全不同的实现：
        // 录音只是「麦克风 + 前台服务」，录像还要把相机交给服务持有，
        // 所以必须声明 foregroundServiceType="camera"（见 AndroidManifest.xml）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VIDEOREC_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val path = call.argument<String>("path")
                        val lens = call.argument<String>("lens") ?: "back"
                        val audio = call.argument<Boolean>("audio") ?: true
                        val maxMs =
                            (call.argument<Any>("maxDurationMs") as? Number)?.toLong() ?: 0L
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "缺少录像文件路径", null)
                        } else {
                            try {
                                VideoRecorderService.start(
                                    applicationContext, path, lens, audio, maxMs
                                )
                                result.success(true)
                            } catch (t: Throwable) {
                                result.error("start_failed", t.message ?: "启动录像失败", null)
                            }
                        }
                    }
                    "stop" -> {
                        try {
                            VideoRecorderService.stop(applicationContext)
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("stop_failed", t.message ?: "停止录像失败", null)
                        }
                    }
                    "status" -> {
                        val out = HashMap<String, Any?>()
                        out["running"] = VideoRecorderService.running
                        out["elapsedMs"] = VideoRecorderService.elapsedMs()
                        out["error"] = VideoRecorderService.lastError
                        result.success(out)
                    }
                    else -> result.notImplemented()
                }
            }

        // ---- 系统媒体音量（v1.6.0 新增，播放器用）----
        //
        // 为什么要这么一个通道：media_kit 的 setVolume 是**乘在系统音量之上**的系数，
        // 手机媒体音量只有 30% 时播放器系数调到 100% 也还是 30% 的响度 ——
        // 用户得先去按手机侧面的音量键。用户第 1 条要求「不按音量键也能把音量开到最大」，
        // 所以这里直接改 AudioManager 的 STREAM_MUSIC。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL)
            .setMethodCallHandler { call, result ->
                val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                if (am == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "getMusicVolume" -> {
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val cur = am.getStreamVolume(AudioManager.STREAM_MUSIC)
                        // 归一化成 0~100 百分比；max 异常时返回 null，让 Dart 侧退回老逻辑
                        result.success(if (max <= 0) null else cur * 100.0 / max)
                    }
                    "setMusicVolume" -> {
                        val pct = call.argument<Int>("percent") ?: 0
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        if (max <= 0) {
                            result.success(false)
                        } else {
                            val target = Math.round(pct.coerceIn(0, 100) * max / 100.0).toInt()
                            try {
                                // flags = 0：不弹系统音量条，免得挡画面
                                am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                                result.success(true)
                            } catch (t: Throwable) {
                                result.error("set_failed", t.message ?: "设置音量失败", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        stopLocation()
        super.onDestroy()
    }

    // ---------------------------------------------------------------- 定位

    private fun startLocation(sink: EventChannel.EventSink) {
        stopLocation()
        locationSink = sink
        val lm = try {
            getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        } catch (t: Throwable) {
            null
        }
        if (lm == null) {
            safeError(sink, "no_service", "这台设备没有定位服务")
            return
        }
        locationManager = lm
        try {
            // 先把系统缓存里的最后位置推一次，界面不用空着等
            lastKnown(lm)?.let { emitLocation(it) }

            var started = false
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                lm.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER, 1000L, 0f, locationListener, Looper.getMainLooper()
                )
                started = true
            }
            if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                lm.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER, 2000L, 0f, locationListener, Looper.getMainLooper()
                )
                started = true
            }
            if (!started) {
                safeError(sink, "provider_off", "系统的定位开关没打开（去「设置 → 位置信息」里打开）")
            }
        } catch (t: Throwable) {
            // 最常见的就是 SecurityException：用户没给定位权限
            safeError(sink, "denied", t.message ?: "定位权限不可用")
        }
    }

    private fun stopLocation() {
        try {
            locationManager?.removeUpdates(locationListener)
        } catch (t: Throwable) {
            // 忽略：本来就没挂上
        }
        locationManager = null
        locationSink = null
    }

    private fun lastKnown(lm: LocationManager): Location? {
        var best: Location? = null
        for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            try {
                val l = lm.getLastKnownLocation(p) ?: continue
                if (best == null || l.time > best.time) best = l
            } catch (t: Throwable) {
                // 没有权限时这里会抛，直接跳过
            }
        }
        return best
    }

    private fun emitLocation(l: Location) {
        val sink = locationSink ?: return
        val out = HashMap<String, Any?>()
        out["lat"] = l.latitude
        out["lon"] = l.longitude
        if (l.hasAltitude()) out["alt"] = l.altitude
        if (l.hasAccuracy()) out["accuracy"] = l.accuracy.toDouble()
        if (l.hasSpeed()) out["speed"] = l.speed.toDouble()
        if (l.hasBearing()) out["bearing"] = l.bearing.toDouble()
        out["provider"] = if (l.provider == LocationManager.GPS_PROVIDER) "gps" else "network"
        out["time"] = l.time
        try {
            sink.success(out)
        } catch (t: Throwable) {
            // 通道已经关了（页面退出）—— 停掉定位就行
            stopLocation()
        }
    }

    private fun safeError(sink: EventChannel.EventSink, code: String, msg: String) {
        try {
            sink.error(code, msg, null)
        } catch (t: Throwable) {
            // 通道可能已经不在了
        }
    }

    /**
     * Android 11 起 `resources.displayMetrics` 返回的是「当前窗口」的 metrics，
     * 但 xdpi / ydpi 描述的是**面板本身**，不随窗口大小变化，所以仍然可用。
     * 落在这个区间外的值基本可以确定是乱报：
     *   下界 100 dpi —— 1985 年的显示器都比这高；
     *   上界 1200 dpi —— 索尼那台 4K 手机约 806，已经很极端了。
     */
    private fun readPhysicalDpi(): Map<String, Double>? {
        return try {
            val dm: DisplayMetrics = resources.displayMetrics
            val x = dm.xdpi.toDouble()
            val y = dm.ydpi.toDouble()
            val sane = x.isFinite() && y.isFinite() &&
                x > 100.0 && x < 1200.0 && y > 100.0 && y < 1200.0
            if (sane) mapOf("xdpi" to x, "ydpi" to y) else null
        } catch (t: Throwable) {
            null
        }
    }

    /**
     * 锁定到当前朝向。返回 true 表示调用成功（方向本身是否立刻生效由系统决定）；
     * 抛异常时返回 false，Dart 侧会退到「只允许当前那一族方向」的近似方案。
     *
     * 必须跑在主线程：`setRequestedOrientation` 是 View/Activity 的 API。
     * Flutter 的 MethodCallHandler 默认就在平台主线程回调，所以直接调没问题。
     */
    private fun lockCurrentOrientation(): Boolean {
        return try {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LOCKED
            true
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 打开「跟着手机方向自动翻转」。返回 true 表示原生这条路走通了。
     *
     * 用 `SCREEN_ORIENTATION_SENSOR` 而不是 `USER`：只有 SENSOR 才不管用户
     * 有没有在系统设置里关掉「自动旋转」。详见文件顶部第 3 点的说明。
     *
     * 为什么不用 `FULL_SENSOR`：那玩意连「倒着拿手机」（反向竖屏）也认，
     * 用户躺着看视频时画面会莫名其妙上下颠倒，体验很差。SENSOR 不含反向竖屏，
     * 正好对应 Flutter 那套「竖屏 + 左横屏 + 右横屏」。
     *
     * 抛异常时返回 false，Dart 侧会退到 `setPreferredOrientations` 的老路
     * （在系统自动旋转开着的时候仍然好用）。
     */
    private fun followOrientation(): Boolean {
        return try {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR
            true
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * 后台录音服务。
     *
     * 状态全放在 companion object 上（进程内单例）：Dart 侧每秒钟问一次 `status`，
     * 拿的就是这几个值。用 @Volatile 是因为写它的是服务线程、读它的是平台主线程。
     *
     * 出错不抛给 Dart，而是写进 `lastError`：
     *   录音是「开了就该一直跑」的东西，中途某次 prepare 失败要让用户看到原因
     *   （比如麦克风被别的应用占着），而不是整个工具页崩掉。
     */
    class RecorderService : Service() {

        private var recorder: MediaRecorder? = null
        private var wakeLock: PowerManager.WakeLock? = null

        /**
         * 「最长录多久」的定时器（v1.6.0 新增）。
         *
         * 用 Handler 而不是 Dart 侧的 Timer：服务必须自己收尾 ——
         * 用户设置了「最多录 30 分钟」然后切后台，Dart 侧早就被冻结了，
         * 只有原生这条定时器能保证到点真的停下来并把文件写完。
         */
        private val main = Handler(Looper.getMainLooper())
        private var stopRunnable: Runnable? = null

        override fun onBind(intent: Intent?): IBinder? = null

        override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
            val path = intent?.getStringExtra(EXTRA_PATH)
            if (path.isNullOrBlank()) {
                stopSelf()
                return START_NOT_STICKY
            }
            val maxMs = intent.getLongExtra(EXTRA_MAX_MS, 0L)
            // 已经在录了就别重开：会盖掉上一段
            if (running) return START_STICKY
            return try {
                startForegroundCompat()
                acquireWakeLock()
                startRecorder(path)
                running = true
                lastError = null
                startedAt = System.currentTimeMillis()
                scheduleAutoStop(maxMs)
                START_STICKY
            } catch (t: Throwable) {
                lastError = t.message ?: t.javaClass.simpleName
                running = false
                releaseAll()
                stopSelf()
                START_NOT_STICKY
            }
        }

        /**
         * 到点自动停。`maxMs <= 0` 表示不限时长。
         *
         * 走 `stopSelf()` 而不是直接 release：让 onDestroy 里那条收尾路径
         * 统一处理（停止 / 释放 / 撤通知），只有一处逻辑才不容易漏。
         */
        private fun scheduleAutoStop(maxMs: Long) {
            cancelAutoStop()
            if (maxMs <= 0L) return
            val r = Runnable {
                // 到点了：把录音停掉，通知也随之收掉
                stopSelf()
            }
            stopRunnable = r
            main.postDelayed(r, maxMs)
        }

        private fun cancelAutoStop() {
            val r = stopRunnable ?: return
            main.removeCallbacks(r)
            stopRunnable = null
        }

        override fun onDestroy() {
            releaseAll()
            running = false
            startedAt = 0L
            try {
                stopForeground(true)
            } catch (t: Throwable) {
                // 忽略：有的 ROM 在这时候已经自己收了
            }
            super.onDestroy()
        }

        private fun startForegroundCompat() {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "后台录音", NotificationManager.IMPORTANCE_LOW
                )
                ch.description = "录音进行中显示的常驻通知"
                nm.createNotificationChannel(ch)
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            val notif: Notification = builder
                .setContentTitle("学聚正在录音")
                .setContentText("息屏、切到后台都会继续录")
                .setSmallIcon(applicationInfo.icon)
                .setOngoing(true)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10 起可以显式声明前台服务类型；
                // Android 14 起「麦克风」这一类是硬要求，必须声明。
                startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIF_ID, notif)
            }
        }

        private fun acquireWakeLock() {
            try {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "studyhub:recorder")
                lock.setReferenceCounted(false)
                lock.acquire()
                wakeLock = lock
            } catch (t: Throwable) {
                // 拿不到唤醒锁也继续录 —— 只是息屏久了可能被系统降频
                wakeLock = null
            }
        }

        private fun startRecorder(path: String) {
            val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            // MPEG_4 + AAC = 手机和电脑都能直接播的 .m4a，体积也合适
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(44100)
            r.setAudioEncodingBitRate(96000)
            r.setOutputFile(path)
            r.prepare()
            r.start()
            recorder = r
        }

        private fun releaseAll() {
            cancelAutoStop()
            try {
                recorder?.stop()
            } catch (t: Throwable) {
                // 还没真正开始录就 stop 会抛 IllegalStateException —— 正常现象。
                // 这种情况下文件可能只有个空壳，交给 Dart 侧按大小判断。
            }
            try {
                recorder?.release()
            } catch (t: Throwable) {
                // 忽略
            }
            recorder = null
            try {
                val lock = wakeLock
                if (lock != null && lock.isHeld) lock.release()
            } catch (t: Throwable) {
                // 忽略
            }
            wakeLock = null
        }

        companion object {
            const val EXTRA_PATH = "path"
            const val EXTRA_MAX_MS = "maxMs"
            private const val CHANNEL_ID = "studyhub_recorder"
            private const val NOTIF_ID = 4101

            @Volatile
            var running: Boolean = false

            @Volatile
            var lastError: String? = null

            @Volatile
            var startedAt: Long = 0L

            fun start(context: Context, path: String, maxDurationMs: Long = 0L) {
                lastError = null
                val i = Intent(context, RecorderService::class.java)
                i.putExtra(EXTRA_PATH, path)
                i.putExtra(EXTRA_MAX_MS, maxDurationMs)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(i)
                } else {
                    context.startService(i)
                }
            }

            fun stop(context: Context) {
                try {
                    context.stopService(Intent(context, RecorderService::class.java))
                } catch (t: Throwable) {
                    // 忽略：本来就没在跑
                }
            }

            fun elapsedMs(): Long {
                val t0 = startedAt
                if (!running || t0 <= 0L) return 0L
                return System.currentTimeMillis() - t0
            }
        }
    }

    /**
     * 后台录像服务（v1.6.0 新增）。
     *
     * ── 为什么值得单独写一个服务 ────────────────────────────
     * 原来的录像走 Flutter 的 `camera` 插件，只能在**前台**录：
     * 一退到后台，Android 9 起会直接把相机会话掐掉，文件写不完。
     * 但「退到后台也能录」是完全可以做到的 —— 关键是把相机放进一个
     * `foregroundServiceType="camera"` 的**前台服务**里（这也是 Alibi 的做法：
     * 它的 VideoRecorderService 用的就是 android:foregroundServiceType="camera"）。
     * 官方文档写得很清楚：camera 类型的前台服务可以「继续在后台访问相机」，
     * 唯一的限制是**必须在前台启动**这个服务 —— 用户正是在前台点的「开始录像」，
     * 完全满足。
     *
     * ── 为什么没有预览画面 ──────────────────────────────────
     * 相机只能有一个持有者。前台服务的相机句柄一旦交给服务，Activity 这边
     * 就没有画面可显示了（要么服务录、要么页面预览，二选一）。
     * 好在「后台录像」这个场景本来就不需要盯着看（放兜里、当行车记录仪）。
     * 想要画面的话，页面上还有一条「前台录像（有画面）」的路。
     *
     * ── 用 Camera2 而不是 CameraX ──────────────────────────
     * Camera2 是系统框架自带的（`android.hardware.camera2.*`），
     * 不需要往 build.gradle 里加任何依赖 —— 这个项目的云端构建流程
     * 只注入一个 MainActivity.kt 和一个 AndroidManifest.xml，
     * 加 Gradle 依赖意味着还要改工作流，多一处可能失败的环节。
     *
     * ── 录制链路 ────────────────────────────────────────────
     * CameraManager.openCamera → MediaRecorder.prepare → 拿 `recorder.surface`
     * 当作 capture target → 开一个 TEMPLATE_RECORD 的重复请求。
     * 另外挂了一块**假 Surface**（`SurfaceTexture(10)`）当第二个 target：
     * 一部分 ROM 在「没有预览 target」时会拒绝开会话，加上它就稳了
     * （这些帧没人消费，直接丢掉，不耗什么）。
     */
    class VideoRecorderService : Service() {

        private var camera: CameraDevice? = null
        private var session: CameraCaptureSession? = null
        private var recorder: MediaRecorder? = null
        private var dummyTexture: SurfaceTexture? = null
        private var dummySurface: Surface? = null
        private var thread: HandlerThread? = null
        private var handler: Handler? = null
        private var wakeLock: PowerManager.WakeLock? = null
        private var stopRunnable: Runnable? = null

        override fun onBind(intent: Intent?): IBinder? = null

        override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
            val path = intent?.getStringExtra(EXTRA_PATH)
            if (path.isNullOrBlank()) {
                stopSelf()
                return START_NOT_STICKY
            }
            if (running) return START_STICKY
            val front = intent.getStringExtra(EXTRA_LENS) == "front"
            val withAudio = intent.getBooleanExtra(EXTRA_AUDIO, true)
            val maxMs = intent.getLongExtra(EXTRA_MAX_MS, 0L)
            return try {
                startForegroundCompat(withAudio)
                acquireWakeLock()
                startBackgroundThread()
                val h = handler ?: throw IllegalStateException("录像线程没起来")
                openAndRecord(path, front, withAudio, h)
                running = true
                lastError = null
                startedAt = System.currentTimeMillis()
                scheduleAutoStop(maxMs, h)
                START_STICKY
            } catch (t: Throwable) {
                lastError = t.message ?: t.javaClass.simpleName
                running = false
                releaseAll()
                stopSelf()
                START_NOT_STICKY
            }
        }

        override fun onDestroy() {
            releaseAll()
            running = false
            startedAt = 0L
            try {
                stopForeground(true)
            } catch (t: Throwable) {
                // 忽略
            }
            super.onDestroy()
        }

        // ------------------------------------------------ 前台通知与唤醒锁

        private fun startForegroundCompat(withAudio: Boolean) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "后台录像", NotificationManager.IMPORTANCE_LOW
                )
                ch.description = "录像进行中显示的常驻通知"
                nm.createNotificationChannel(ch)
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            val notif: Notification = builder
                .setContentTitle("学聚正在录像")
                .setContentText("息屏、切到后台都会继续录")
                .setSmallIcon(applicationInfo.icon)
                .setOngoing(true)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                if (withAudio) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIF_ID, notif, types)
            } else {
                startForeground(NOTIF_ID, notif)
            }
        }

        private fun acquireWakeLock() {
            try {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "studyhub:videorec")
                lock.setReferenceCounted(false)
                lock.acquire()
                wakeLock = lock
            } catch (t: Throwable) {
                wakeLock = null
            }
        }

        // ------------------------------------------------ 线程

        private fun startBackgroundThread() {
            val t = HandlerThread("studyhub-videorec")
            t.start()
            thread = t
            handler = Handler(t.looper)
        }

        private fun stopBackgroundThread() {
            val t = thread
            thread = null
            handler = null
            if (t == null) return
            t.quitSafely()
            try {
                t.join(500)
            } catch (e: InterruptedException) {
                // 忽略：线程本来就要结束了
            }
        }

        // ------------------------------------------------ 录制

        private fun openAndRecord(path: String, front: Boolean, withAudio: Boolean, h: Handler) {
            val cm = getSystemService(Context.CAMERA_SERVICE) as? CameraManager
                ?: throw IllegalStateException("这台设备没有相机服务")
            val wantFacing = if (front) {
                CameraCharacteristics.LENS_FACING_FRONT
            } else {
                CameraCharacteristics.LENS_FACING_BACK
            }
            val id = pickCameraId(cm, wantFacing)
                ?: throw IllegalStateException("没有找到可用的摄像头")
            val chars = cm.getCameraCharacteristics(id)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?: throw IllegalStateException("读不到摄像头参数")
            val size = pickSize(map.getOutputSizes(MediaRecorder::class.java))
                ?: throw IllegalStateException("这台设备的摄像头不支持录像")

            val rec = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            rec.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            if (withAudio) {
                rec.setAudioSource(MediaRecorder.AudioSource.MIC)
                rec.setAudioChannels(1)
                rec.setAudioSamplingRate(44100)
                rec.setAudioEncodingBitRate(96000)
            }
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            rec.setVideoSize(size.width, size.height)
            rec.setVideoFrameRate(30)
            rec.setVideoEncodingBitRate(bitrateFor(size))
            rec.setOrientationHint(orientationHint(chars, front))
            rec.setOutputFile(path)
            rec.prepare()
            recorder = rec

            // 假 Surface：给会话凑一个「不消费」的 target，见类注释
            val tex = SurfaceTexture(10)
            dummyTexture = tex
            val dummy = Surface(tex)
            dummySurface = dummy
            val targets = listOf<Surface>(rec.surface, dummy)

            cm.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(dev: CameraDevice) {
                    camera = dev
                    try {
                        @Suppress("DEPRECATION")
                        dev.createCaptureSession(
                            targets,
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(s: CameraCaptureSession) {
                                    session = s
                                    try {
                                        val req = dev.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                        for (t in targets) req.addTarget(t)
                                        req.set(
                                            CaptureRequest.CONTROL_AF_MODE,
                                            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
                                        )
                                        req.set(
                                            CaptureRequest.CONTROL_AE_MODE,
                                            CaptureRequest.CONTROL_AE_MODE_ON
                                        )
                                        s.setRepeatingRequest(req.build(), null, h)
                                        // 会话跑起来了才真正开始写文件
                                        rec.start()
                                    } catch (t: Throwable) {
                                        fail(t)
                                    }
                                }

                                override fun onConfigureFailed(s: CameraCaptureSession) {
                                    fail(IllegalStateException("相机会话配置失败"))
                                }
                            },
                            h
                        )
                    } catch (t: Throwable) {
                        fail(t)
                    }
                }

                override fun onDisconnected(dev: CameraDevice) {
                    dev.close()
                    if (camera === dev) camera = null
                }

                override fun onError(dev: CameraDevice, error: Int) {
                    fail(IllegalStateException("相机打开出错（code=$error）"))
                    dev.close()
                }
            }, h)
        }

        /** 相机侧失败：把原因留下来，让 Dart 侧轮询时能看到，然后收摊。 */
        private fun fail(t: Throwable) {
            lastError = t.message ?: t.javaClass.simpleName
            running = false
            releaseAll()
            stopSelf()
        }

        private fun scheduleAutoStop(maxMs: Long, h: Handler) {
            cancelAutoStop()
            if (maxMs <= 0L) return
            val r = Runnable { stopSelf() }
            stopRunnable = r
            h.postDelayed(r, maxMs)
        }

        private fun cancelAutoStop() {
            val r = stopRunnable ?: return
            handler?.removeCallbacks(r)
            stopRunnable = null
        }

        private fun releaseAll() {
            cancelAutoStop()
            try {
                session?.stopRepeating()
            } catch (t: Throwable) {
                // 忽略
            }
            try {
                session?.close()
            } catch (t: Throwable) {
                // 忽略
            }
            session = null
            try {
                camera?.close()
            } catch (t: Throwable) {
                // 忽略
            }
            camera = null
            try {
                recorder?.stop()
            } catch (t: Throwable) {
                // 还没真正开始录就 stop 会抛 IllegalStateException —— 正常现象。
                // 这时候文件可能只是个空壳，交给 Dart 侧按大小判断并删掉。
            }
            try {
                recorder?.reset()
            } catch (t: Throwable) {
                // 忽略
            }
            try {
                recorder?.release()
            } catch (t: Throwable) {
                // 忽略
            }
            recorder = null
            try {
                dummySurface?.release()
            } catch (t: Throwable) {
                // 忽略
            }
            dummySurface = null
            try {
                dummyTexture?.release()
            } catch (t: Throwable) {
                // 忽略
            }
            dummyTexture = null
            try {
                val lock = wakeLock
                if (lock != null && lock.isHeld) lock.release()
            } catch (t: Throwable) {
                // 忽略
            }
            wakeLock = null
            stopBackgroundThread()
        }

        private fun pickCameraId(cm: CameraManager, facing: Int): String? {
            return try {
                var fallback: String? = null
                for (id in cm.cameraIdList) {
                    val f = cm.getCameraCharacteristics(id)
                        .get(CameraCharacteristics.LENS_FACING)
                    if (fallback == null) fallback = id
                    if (f != null && f == facing) return id
                }
                // 想要的那一侧不存在（比如很多机器没有前置）→ 退回随便一个能用的，
                // 总比直接失败强
                fallback
            } catch (t: Throwable) {
                null
            }
        }

        /** 从摄像头支持的那堆尺寸里挑一个最接近 1080p 的。 */
        private fun pickSize(sizes: Array<Size>?): Size? {
            if (sizes == null || sizes.isEmpty()) return null
            val target = 1920L * 1080L
            var best = sizes[0]
            var bestDiff = Long.MAX_VALUE
            for (s in sizes) {
                val d = Math.abs(s.width.toLong() * s.height.toLong() - target)
                if (d < bestDiff) {
                    bestDiff = d
                    best = s
                }
            }
            return best
        }

        private fun bitrateFor(size: Size): Int {
            // 约 4 bit/像素/帧 × 30 帧的经验值，再夹到 2~20 Mbps
            val v = size.width.toLong() * size.height.toLong() * 4L
            return v.coerceIn(2_000_000L, 20_000_000L).toInt()
        }

        /**
         * 让录出来的画面是正的。
         *
         * 传感器方向和手机朝向是两回事：竖屏拿着手机时，传感器常常是横的，
         * 不给 orientationHint 的话录出来会躺在那里。这个页面锁竖屏，
         * 所以按竖屏换算即可；前置镜头是镜像的，要多转 180°。
         */
        private fun orientationHint(chars: CameraCharacteristics, front: Boolean): Int {
            val so = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            return if (front) (so + 180) % 360 else so
        }

        companion object {
            const val EXTRA_PATH = "path"
            const val EXTRA_LENS = "lens"
            const val EXTRA_AUDIO = "audio"
            const val EXTRA_MAX_MS = "maxMs"
            private const val CHANNEL_ID = "studyhub_videorec"
            private const val NOTIF_ID = 4102

            @Volatile
            var running: Boolean = false

            @Volatile
            var lastError: String? = null

            @Volatile
            var startedAt: Long = 0L

            fun start(
                context: Context,
                path: String,
                lens: String,
                withAudio: Boolean,
                maxDurationMs: Long
            ) {
                lastError = null
                val i = Intent(context, VideoRecorderService::class.java)
                i.putExtra(EXTRA_PATH, path)
                i.putExtra(EXTRA_LENS, lens)
                i.putExtra(EXTRA_AUDIO, withAudio)
                i.putExtra(EXTRA_MAX_MS, maxDurationMs)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(i)
                } else {
                    context.startService(i)
                }
            }

            fun stop(context: Context) {
                try {
                    context.stopService(Intent(context, VideoRecorderService::class.java))
                } catch (t: Throwable) {
                    // 忽略：本来就没在跑
                }
            }

            fun elapsedMs(): Long {
                val t0 = startedAt
                if (!running || t0 <= 0L) return 0L
                return System.currentTimeMillis() - t0
            }
        }
    }

    companion object {
        private const val CHANNEL = "studyhub/display"
        private const val LOCATION_CHANNEL = "studyhub/location"
        private const val RECORDER_CHANNEL = "studyhub/recorder"
        private const val AUDIO_CHANNEL = "studyhub/audio"
        private const val VIDEOREC_CHANNEL = "studyhub/videorec"
    }
}
