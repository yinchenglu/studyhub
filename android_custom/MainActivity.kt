package __PACKAGE__

import android.util.DisplayMetrics
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 学聚的自定义 MainActivity。
 *
 * 只有一个职责：把**面板真实物理 DPI** 交给 Dart 侧。
 *
 * 为什么要这个：
 *   直尺工具要按真实尺寸显示刻度，需要知道「1 个逻辑像素等于多少英寸」。
 *   Flutter 的 `devicePixelRatio` 只给了「逻辑像素 → 物理像素」这一半关系，
 *   另一半「物理像素 → 英寸」必须问系统要 —— 也就是 `DisplayMetrics.xdpi`。
 *   Flutter 框架没有暴露它，所以自己架一个 MethodChannel。
 *
 * 为什么不直接用 `densityDpi`：
 *   那是厂商从 240 / 320 / 420 / 480 这些档位里挑的**标称值**。
 *   真实 6.7 吋 1080x2400 的面板物理密度约 393，厂商很可能填 420，
 *   照它画出来的尺子整套偏小 6.9%，量 30 cm 差 2 cm。
 *   `xdpi / ydpi` 才是驱动上报的真实值。
 *
 * 出错一律返回 null：
 *   Dart 侧会回退到「1 英寸 = 160 逻辑像素」的默认近似。
 *   尺子略微不准可以接受，工具页崩掉不行。
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "physicalDpi" -> result.success(readPhysicalDpi())
                    else -> result.notImplemented()
                }
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

    companion object {
        private const val CHANNEL = "studyhub/display"
    }
}
