package com.hiddify.hiddify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.provider.Settings as AndroidSettings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.FileProvider
import java.io.File
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.Observer
import com.hiddify.hiddify.bg.ServiceNotification
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.JSONMethodCodec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Окно: борьба с чужими VPN.
 *
 * Android держит только один VPN-туннель. Если у пользователя остался старый клиент
 * (Happ, v2rayNG, Hiddify…) с автоподключением, он перехватывает туннель, система зовёт
 * onRevoke у нас и «Окно» молча выключалось. Здесь:
 *  - `foreign_vpn`  — что мешает: активен ли чужой туннель прямо сейчас, какие VPN-клиенты
 *                     стоят на телефоне, кто назначен «постоянным VPN» (best-effort через
 *                     Settings.Secure) и не мы ли это;
 *  - `open_vpn_settings` / `open_app` / `open_app_settings` / `uninstall` — кнопки экрана
 *                     «Мешает другой VPN» (системные экраны, ничего скрытно не делаем);
 *  - события `revoked` → Dart (показать экран + предложить подключить снова) и уведомление,
 *                     чтобы человек понял, ПОЧЕМУ его «выкинуло».
 */
class OknoChannel : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "A/OknoChannel"
        const val METHOD_CHANNEL = "com.hiddify.app/okno"
        const val EVENT_CHANNEL = "com.hiddify.app/okno.events"
        private const val ALERT_CHANNEL_ID = "okno_alerts"
        private const val REVOKED_NOTIFICATION_ID = 4101

        /** Последнее событие для Dart (LiveData, чтобы не потерять его, пока экран не слушает). */
        val events = MutableLiveData<Map<String, Any?>?>(null)

        /** Момент последнего перехвата (для Dart: «только что» vs старое). */
        @Volatile
        var lastRevokedAt: Long = 0L

        /** Зовётся из BoxService.onRevoke — система отдала туннель другому приложению. */
        fun onRevokedByOtherVpn(context: Context) {
            lastRevokedAt = System.currentTimeMillis()
            val info = try { foreignVpnInfo(context, selfStopped = true) } catch (e: Exception) { emptyMap() }
            Log.w(TAG, "VPN revoked by another app: $info")
            events.postValue(mapOf("event" to "revoked", "at" to lastRevokedAt) + info)
            showRevokedNotification(context, info)
        }

        private fun showRevokedNotification(context: Context, info: Map<String, Any?>) {
            try {
                if (!ServiceNotification.checkPermission()) return
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(
                        NotificationChannel(ALERT_CHANNEL_ID, "Окно — важные сообщения", NotificationManager.IMPORTANCE_HIGH)
                    )
                }
                @Suppress("UNCHECKED_CAST")
                val apps = (info["apps"] as? List<Map<String, Any?>>)?.mapNotNull { it["label"] as? String } ?: emptyList()
                val who = if (apps.isEmpty()) "другое VPN-приложение" else apps.joinToString(", ")
                val intent = Intent(context, MainActivity::class.java)
                    .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    .putExtra("okno_revoked", true)
                val pi = PendingIntent.getActivity(context, 41, intent, ServiceNotification.flags)
                val n = NotificationCompat.Builder(context, ALERT_CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_logo)
                    .setContentTitle("Окно отключено: мешает другой VPN")
                    .setContentText("Соединение перехватило $who. Нажмите, чтобы вернуть Окно.")
                    .setStyle(NotificationCompat.BigTextStyle().bigText(
                        "Соединение перехватило $who. На телефоне может работать только один VPN. " +
                            "Откройте Окно — покажем, что выключить или удалить, и подключим снова."
                    ))
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setCategory(NotificationCompat.CATEGORY_ERROR)
                    .setAutoCancel(true)
                    .setContentIntent(pi)
                    .build()
                nm.notify(REVOKED_NOTIFICATION_ID, n)
            } catch (e: Exception) {
                Log.w(TAG, "revoked notification failed: ${e.message}")
            }
        }

        /** Есть ли сейчас в системе VPN-сеть. Когда наша служба остановлена — это чужой туннель. */
        fun isAnyVpnActive(context: Context): Boolean {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            return cm.allNetworks.any { n ->
                cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            }
        }

        /** Установленные VPN-клиенты (кроме нас). QUERY_ALL_PACKAGES у нас уже объявлен. */
        fun installedVpnApps(context: Context): List<Map<String, Any?>> {
            val pm = context.packageManager
            val intent = Intent(VpnService.SERVICE_INTERFACE)
            val list = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.queryIntentServices(intent, PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_ALL.toLong()))
            } else {
                @Suppress("DEPRECATION")
                pm.queryIntentServices(intent, PackageManager.MATCH_ALL)
            }
            return list.asSequence()
                .map { it.serviceInfo.packageName }
                .distinct()
                .filter { it != context.packageName }
                .map { pkg ->
                    val label = try { pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString() } catch (e: Exception) { pkg }
                    mapOf("package" to pkg, "label" to label)
                }
                .toList()
        }

        /** Пакет «постоянного VPN» (Settings.Secure.always_on_vpn_app) — скрытый ключ, читаем best-effort. */
        fun alwaysOnPackage(context: Context): String? = try {
            AndroidSettings.Secure.getString(context.contentResolver, "always_on_vpn_app")?.takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            null
        }

        fun foreignVpnInfo(context: Context, selfStopped: Boolean): Map<String, Any?> {
            val apps = installedVpnApps(context)
            val alwaysOn = alwaysOnPackage(context)
            val selfRunning = MainActivity.instanceOrNull()?.serviceStatus?.value == com.hiddify.hiddify.constant.Status.Started
            val active = isAnyVpnActive(context) && (selfStopped || !selfRunning)
            return mapOf(
                "active" to active,
                "apps" to apps,
                "always_on_package" to alwaysOn,
                "always_on_self" to (alwaysOn == context.packageName),
                "always_on_foreign" to (alwaysOn != null && alwaysOn != context.packageName),
                "self_package" to context.packageName,
                "last_revoked_at" to lastRevokedAt,
            )
        }
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var observer: Observer<Map<String, Any?>?>? = null
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        cleanupUpdates(context)
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL, JSONMethodCodec.INSTANCE).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    observer = Observer { ev -> if (ev != null) sink?.success(ev) }
                    events.observeForever(observer!!)
                }

                override fun onCancel(arguments: Any?) {
                    observer?.let { events.removeObserver(it) }
                    observer = null
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        observer?.let { events.removeObserver(it) }
        eventChannel?.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "foreign_vpn" -> result.success(foreignVpnInfo(context, selfStopped = false))
                "consume_revoked" -> {
                    // Dart прочитал событие — сбрасываем, чтобы не показывать повторно, и убираем уведомление
                    events.postValue(null)
                    (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(REVOKED_NOTIFICATION_ID)
                    result.success(true)
                }
                "open_vpn_settings" -> result.success(startSafely(Intent(AndroidSettings.ACTION_VPN_SETTINGS)))
                "open_app" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    val launch = context.packageManager.getLaunchIntentForPackage(pkg)
                    result.success(launch != null && startSafely(launch))
                }
                "open_app_settings" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    result.success(startSafely(Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))))
                }
                // Обновление из приложения: Dart скачал APK в filesDir/updates → системный установщик.
                // Android 8+: нужно разрешение «установка из этого источника» — откроем настройку, Dart попросит нажать ещё раз.
                "can_install" -> result.success(canInstall(context))
                "install_apk" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(installApk(context, path))
                }
                "updates_dir" -> result.success(updatesDir(context).absolutePath)
                // Производитель/модель — для подсказок «разрешите работу в фоне» (Xiaomi/Samsung/Huawei убивают VPN)
                "device_info" -> result.success(mapOf(
                    "manufacturer" to Build.MANUFACTURER, "brand" to Build.BRAND, "model" to Build.MODEL,
                    "sdk" to Build.VERSION.SDK_INT, "release" to Build.VERSION.RELEASE,
                    "miui" to (Build.MANUFACTURER.equals("Xiaomi", true) || Build.BRAND.equals("Redmi", true) || Build.BRAND.equals("POCO", true)),
                ))
                // Экран автозапуска (MIUI и др.) — best effort, иначе настройки приложения
                "open_autostart" -> result.success(openAutostart(context))
                "uninstall" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    // системный диалог удаления — пользователь подтверждает сам
                    result.success(startSafely(Intent(Intent.ACTION_DELETE, Uri.parse("package:$pkg"))))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("OKNO", e.message, null)
        }
    }

    private fun openAutostart(ctx: Context): Boolean {
        val candidates = listOf(
            Intent("miui.intent.action.OP_AUTO_START").addCategory(Intent.CATEGORY_DEFAULT),
            Intent().setClassName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            Intent().setClassName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            Intent().setClassName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
            Intent().setClassName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            Intent().setClassName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
        )
        for (i in candidates) {
            try {
                if (ctx.packageManager.resolveActivity(i, 0) != null && startSafely(i)) return true
            } catch (_: Exception) {}
        }
        return startSafely(Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}")))
    }

    private fun updatesDir(ctx: Context): File = File(ctx.filesDir, "updates").apply { mkdirs() }

    /** Старые скачанные обновления — в мусор при каждом запуске (после установки файл уже не нужен). */
    private fun cleanupUpdates(ctx: Context) {
        try {
            val cur = ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: ""
            updatesDir(ctx).listFiles()?.forEach { f ->
                // файл текущей версии (только что поставленной) или любой старше суток — удаляем
                if (f.name.contains(cur) || System.currentTimeMillis() - f.lastModified() > 86_400_000L) f.delete()
            }
        } catch (e: Exception) {
            Log.w(TAG, "cleanupUpdates: ${e.message}")
        }
    }

    private fun canInstall(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || ctx.packageManager.canRequestPackageInstalls()

    /** "started" — установщик открыт; "need_permission" — открыт экран разрешения; иначе текст ошибки. */
    private fun installApk(ctx: Context, path: String): String {
        val f = File(path)
        if (!f.isFile) return "file not found"
        if (!canInstall(ctx)) {
            startSafely(Intent(AndroidSettings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}")))
            return "need_permission"
        }
        return try {
            val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.okno.fileprovider", f)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            if (startSafely(intent)) "started" else "installer not available"
        } catch (e: Exception) {
            Log.w(TAG, "installApk: ${e.message}")
            e.message ?: "install failed"
        }
    }

    private fun startSafely(intent: Intent): Boolean = try {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        (MainActivity.instanceOrNull() ?: context).startActivity(intent)
        true
    } catch (e: Exception) {
        Log.w(TAG, "startActivity failed: ${e.message}")
        false
    }
}
