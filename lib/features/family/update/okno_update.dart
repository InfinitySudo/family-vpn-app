import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartx/dartx.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:version/version.dart';

/// Проверка обновлений «Окна» по последнему релизу GitHub.
///
/// Источник правды — релиз (тег `vX.Y.Z-okno`), а не коммит: коммит сам по себе
/// не даёт установочных файлов, их собирает GitHub Actions по тегу. Проверяем при
/// запуске и дальше каждые 12 часов (2 раза в сутки), плюс вручную из настроек.
const String oknoTestFlightUrl = "https://testflight.apple.com/join/UJYhuaWF";
const Duration oknoUpdateInterval = Duration(hours: 12);

class OknoUpdateInfo {
  const OknoUpdateInfo({
    required this.version,
    required this.current,
    required this.downloadUrl,
    required this.releaseUrl,
    required this.publishedAt,
    this.notes = "",
  });

  final String version;
  final String current;
  /// Ссылка на установочный файл для этой платформы (или страница релиза/TestFlight).
  final String downloadUrl;
  final String releaseUrl;
  final DateTime? publishedAt;
  final String notes;

  bool get isNewer {
    try {
      return Version.parse(version) > Version.parse(current);
    } catch (_) {
      return false;
    }
  }
}

/// Файл релиза, который нужен этой платформе.
String? _assetFor(List<dynamic> assets) {
  String? find(bool Function(String name) test) {
    for (final a in assets) {
      if (a is Map && test((a["name"] ?? "").toString())) return a["browser_download_url"]?.toString();
    }
    return null;
  }
  if (PlatformUtils.isIOS) return oknoTestFlightUrl;
  if (Platform.isAndroid) {
    return find((n) => n.endsWith("arm64.apk")) ?? find((n) => n.endsWith("universal.apk")) ?? find((n) => n.endsWith(".apk"));
  }
  if (PlatformUtils.isWindows) return find((n) => n.contains("Setup") && n.endsWith(".exe")) ?? find((n) => n.endsWith(".exe"));
  if (PlatformUtils.isMacOS) return find((n) => n.endsWith(".dmg"));
  if (PlatformUtils.isLinux) return find((n) => n.endsWith(".AppImage")) ?? find((n) => n.endsWith(".deb"));
  return null;
}

class OknoUpdateNotifier extends StateNotifier<AsyncValue<OknoUpdateInfo?>> {
  OknoUpdateNotifier(this.ref) : super(const AsyncData(null)) {
    // первая проверка чуть после запуска (не мешаем загрузке подписки), дальше — по расписанию
    _initial = Timer(const Duration(seconds: 20), () => unawaited(check()));
    _timer = Timer.periodic(oknoUpdateInterval, (_) => unawaited(check()));
  }

  final Ref ref;
  Timer? _initial;
  Timer? _timer;
  DateTime? lastCheck;
  /// Версия, которую пользователь отложил кнопкой «позже» (до следующего запуска).
  String? dismissed;

  @override
  void dispose() {
    _initial?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<OknoUpdateInfo?> check({bool manual = false}) async {
    if (state.isLoading) return state.valueOrNull;
    state = const AsyncLoading<OknoUpdateInfo?>().copyWithPrevious(state);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final current = (await ref.read(appInfoProvider.future)).version;
      final req = await client.getUrl(Uri.parse("${Constants.githubReleasesApiUrl}/latest"));
      req.headers.set(HttpHeaders.userAgentHeader, "Okno/$current");
      req.headers.set(HttpHeaders.acceptHeader, "application/vnd.github+json");
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) throw HttpException("GitHub ${resp.statusCode}");
      final body = jsonDecode(await resp.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final tag = (body["tag_name"] ?? "").toString(); // v1.0.8-okno
      final version = tag.replaceFirst(RegExp(r"^v"), "").split("-").first.split("+").first;
      final assets = (body["assets"] as List?) ?? const [];
      final info = OknoUpdateInfo(
        version: version,
        current: current,
        downloadUrl: _assetFor(assets) ?? (body["html_url"] ?? Constants.githubLatestReleaseUrl).toString(),
        releaseUrl: (body["html_url"] ?? Constants.githubLatestReleaseUrl).toString(),
        publishedAt: DateTime.tryParse((body["published_at"] ?? "").toString()),
        notes: (body["body"] ?? "").toString(),
      );
      lastCheck = DateTime.now();
      Logger.bootstrap.info("okno update: latest $version, current $current, newer=${info.isNewer}");
      state = AsyncData(info);
      return info;
    } catch (e, st) {
      Logger.bootstrap.warning("okno update: check failed: $e");
      state = AsyncError<OknoUpdateInfo?>(e, st).copyWithPrevious(state);
      return null;
    } finally {
      client.close(force: true);
    }
  }

  void dismiss(String version) {
    dismissed = version;
    state = AsyncData(state.valueOrNull);
  }

  /// Открыть установочный файл / TestFlight / страницу релиза.
  /// Android: скачиваем APK сами во внутреннюю папку и открываем системный установщик —
  /// без браузера и без кучи файлов в «Загрузках» (см. installAndroid).
  Future<bool> openDownload() async {
    final info = state.valueOrNull;
    if (info == null) return false;
    if (Platform.isAndroid && info.downloadUrl.endsWith(".apk")) {
      return installAndroid(info);
    }
    if (Platform.isMacOS && info.downloadUrl.endsWith(".dmg")) {
      return installMacOS(info);
    }
    if (Platform.isWindows && info.downloadUrl.endsWith(".exe")) {
      return installWindows(info);
    }
    if (Platform.isLinux && info.downloadUrl.endsWith(".AppImage") && (Platform.environment["APPIMAGE"] ?? "").isNotEmpty) {
      return installLinux(info);
    }
    return UriUtils.tryLaunch(Uri.parse(info.downloadUrl));
  }

  /// Linux (AppImage): скачать новый образ, подменить текущий файл ($APPIMAGE), перезапустить.
  Future<bool> installLinux(OknoUpdateInfo info) async {
    if (progress.value != null && progress.value! < 1) return false;
    hint.value = null;
    final target = Platform.environment["APPIMAGE"]!;
    try {
      final dir = await _desktopUpdatesDir();
      final img = File("${dir.path}/Okno-${info.version}.AppImage");
      await _download(info.downloadUrl, img);
      progress.value = 1;
      await Process.run("chmod", ["+x", img.path]);
      final backup = "$target.old";
      await Process.run("mv", ["-f", target, backup]);
      final mv = await Process.run("mv", ["-f", img.path, target]);
      if (mv.exitCode != 0) {
        await Process.run("mv", ["-f", backup, target]);
        throw ProcessException("mv", [target], "${mv.stderr}", mv.exitCode);
      }
      await Process.start("sh", ["-c", 'sleep 1; rm -f "$backup"; "$target" &'], mode: ProcessStartMode.detached);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
    } catch (e) {
      Logger.bootstrap.warning("okno update: linux install failed: $e");
      hint.value = "Не удалось обновить автоматически ($e). Скачайте AppImage со страницы релиза.";
      progress.value = null;
      return false;
    }
  }

  /// Папка для скачанных обновлений на ПК (внутри данных приложения, не «Загрузки»).
  Future<Directory> _desktopUpdatesDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory("${base.path}/updates");
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final f in dir.listSync()) {
      try { f.deleteSync(recursive: true); } catch (_) {}
    }
    return dir;
  }

  /// macOS: dmg → смонтировать → подменить Okno.app там, где он установлен → перезапуск.
  /// Приложение нотаризовано, без App Sandbox, поэтому может заменить собственный бандл
  /// (так делает Sparkle). Запуск прямо из образа dmg (/Volumes) — заменять нечего, просим перетащить в Программы.
  Future<bool> installMacOS(OknoUpdateInfo info) async {
    if (progress.value != null && progress.value! < 1) return false;
    hint.value = null;
    final exe = Platform.resolvedExecutable; // …/Okno.app/Contents/MacOS/okno
    final appPath = Directory(exe).parent.parent.parent.path;
    if (!appPath.endsWith(".app") || appPath.startsWith("/Volumes/")) {
      hint.value = "Сначала перетащите «Окно» в папку Программы и запустите оттуда — тогда обновление пройдёт само.";
      return UriUtils.tryLaunch(Uri.parse(info.downloadUrl));
    }
    final mnt = "${Directory.systemTemp.path}/okno-update-${info.version}";
    try {
      final dir = await _desktopUpdatesDir();
      final dmg = File("${dir.path}/Okno-${info.version}.dmg");
      await _download(info.downloadUrl, dmg);
      progress.value = 1;
      Directory(mnt).createSync(recursive: true);
      final att = await Process.run("hdiutil", ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mnt]);
      if (att.exitCode != 0) throw ProcessException("hdiutil", ["attach"], "${att.stderr}", att.exitCode);
      final newApp = Directory(mnt).listSync().where((e) => e.path.endsWith(".app")).map((e) => e.path).firstOrNull;
      if (newApp == null) throw const FileSystemException("в образе нет .app");
      final backup = "$appPath.old";
      await Process.run("rm", ["-rf", backup]);
      final mv = await Process.run("mv", [appPath, backup]);
      if (mv.exitCode != 0) throw ProcessException("mv", [appPath], "${mv.stderr}", mv.exitCode);
      final cp = await Process.run("ditto", [newApp, appPath]);
      if (cp.exitCode != 0) {
        await Process.run("rm", ["-rf", appPath]);
        await Process.run("mv", [backup, appPath]);
        throw ProcessException("ditto", [newApp], "${cp.stderr}", cp.exitCode);
      }
      await Process.run("xattr", ["-dr", "com.apple.quarantine", appPath]);
      await Process.run("hdiutil", ["detach", mnt, "-quiet"]);
      // перезапуск: дать процессу выйти, убрать старый бандл, открыть новый
      await Process.start("sh", ["-c", 'sleep 1; rm -rf "$backup"; open -n "$appPath"'], mode: ProcessStartMode.detached);
      Logger.bootstrap.info("okno update: macOS bundle replaced, relaunching");
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
    } catch (e) {
      Logger.bootstrap.warning("okno update: macOS install failed: $e");
      await Process.run("hdiutil", ["detach", mnt, "-quiet", "-force"]);
      hint.value = "Не удалось обновить автоматически ($e). Скачайте dmg со страницы релиза.";
      progress.value = null;
      return false;
    }
  }

  /// Windows: скачать Setup.exe и запустить тихую установку поверх (Inno Setup: /SILENT закрывает приложение сам).
  Future<bool> installWindows(OknoUpdateInfo info) async {
    if (progress.value != null && progress.value! < 1) return false;
    hint.value = null;
    try {
      final dir = await _desktopUpdatesDir();
      final setup = File("${dir.path}\\Okno-Setup-${info.version}.exe");
      await _download(info.downloadUrl, setup);
      progress.value = 1;
      await Process.start(setup.path, ["/SILENT", "/CLOSEAPPLICATIONS", "/RESTARTAPPLICATIONS"], mode: ProcessStartMode.detached);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      Logger.bootstrap.warning("okno update: windows install failed: $e");
      hint.value = "Не удалось обновить автоматически ($e). Скачайте установщик со страницы релиза.";
      progress.value = null;
      return false;
    }
  }

  static const _okno = MethodChannel("com.hiddify.app/okno");

  /// Ход обновления на Android: null — не идёт; 0..1 — скачивание; >=1 — передано установщику.
  final ValueNotifier<double?> progress = ValueNotifier(null);
  /// Что показать под плашкой (ошибка / просьба разрешить установку).
  final ValueNotifier<String?> hint = ValueNotifier(null);

  /// Ключ релиза (с 1.0.19; /root/secrets/okno-release.jks). Сборки до него подписаны случайными
  /// debug-ключами CI — поверх них установить релизный APK нельзя, только удалить и поставить заново.
  static const releaseCertSha256 = "CB:A8:FA:A9:68:4F:5C:DC:7B:45:C0:EF:29:62:99:E8:8B:37:19:F8:E8:29:AE:09:18:CB:45:5C:34:F1:14:2B";

  Future<bool> installAndroid(OknoUpdateInfo info) async {
    if (progress.value != null && progress.value! < 1) return false; // уже качаем
    hint.value = null;
    try {
      final sig = await _okno.invokeMethod<String>("signature_sha256") ?? "";
      if (sig.isNotEmpty && sig != releaseCertSha256) {
        hint.value = "Эта копия «Окна» подписана старым ключом, обновить поверх нельзя (один раз). "
            "Удалите «Окно» и поставьте заново со страницы загрузки — дальше будет обновляться само.";
        return UriUtils.tryLaunch(Uri.parse("https://infinitysudo.github.io/family-vpn-app/"));
      }
    } on MissingPluginException {
      // старая нативная часть — без проверки
    } catch (_) {}
    try {
      final dir = Directory(await _okno.invokeMethod<String>("updates_dir") ?? "");
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File("${dir.path}/Okno-${info.version}.apk");
      // прошлые загрузки — в мусор (в т.ч. недокачанные), чтобы не копились
      for (final f in dir.listSync()) {
        if (f is File && f.path != file.path) {
          try { f.deleteSync(); } catch (_) {}
        }
      }
      if (!file.existsSync() || file.lengthSync() < 1024 * 1024) {
        await _download(info.downloadUrl, file);
      }
      progress.value = 1;
      final res = await _okno.invokeMethod<String>("install_apk", {"path": file.path}) ?? "";
      if (res == "need_permission") {
        hint.value = "Разрешите «Окну» устанавливать приложения на открывшемся экране, вернитесь и нажмите «Обновить» ещё раз.";
        progress.value = null;
        return false;
      }
      if (res != "started") {
        hint.value = "Не удалось открыть установщик ($res). Скачайте файл со страницы релиза.";
        progress.value = null;
        return false;
      }
      return true;
    } on MissingPluginException {
      // старая нативная часть — как раньше, через браузер
      progress.value = null;
      return UriUtils.tryLaunch(Uri.parse(info.downloadUrl));
    } catch (e) {
      Logger.bootstrap.warning("okno update: install failed: $e");
      hint.value = "Не удалось скачать обновление: проверьте связь и попробуйте ещё раз.";
      progress.value = null;
      return false;
    }
  }

  Future<void> _download(String url, File file) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final tmp = File("${file.path}.part");
    try {
      progress.value = 0;
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, "Okno-updater");
      final resp = await req.close().timeout(const Duration(seconds: 30)); // редиректы GitHub → objects.githubusercontent.com следуют сами
      if (resp.statusCode != 200) throw HttpException("HTTP ${resp.statusCode}");
      final total = resp.contentLength;
      var got = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) progress.value = (got / total).clamp(0.0, 0.99);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && got != total) throw HttpException("incomplete: $got/$total");
      tmp.renameSync(file.path);
    } catch (_) {
      try { tmp.deleteSync(); } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

final oknoUpdateProvider = StateNotifierProvider<OknoUpdateNotifier, AsyncValue<OknoUpdateInfo?>>(
  (ref) => OknoUpdateNotifier(ref),
);

/// Плашка на главном экране: «Доступна версия X · Обновить».
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.watch(oknoUpdateProvider.notifier);
    final info = ref.watch(oknoUpdateProvider).valueOrNull;
    if (info == null || !info.isNewer || notifier.dismissed == info.version) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final what = PlatformUtils.isIOS
        ? "Откроется TestFlight — нажмите там «Обновить»."
        : Platform.isAndroid
            ? "Обновится прямо здесь: скачаю и предложу установить — подтвердите."
            : "Обновится прямо здесь: скачаю и перезапущу приложение.";
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Icon(Icons.system_update_alt_rounded, color: theme.colorScheme.onTertiaryContainer),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Доступна версия ${info.version}",
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                    Text(
                      "У вас ${info.current}. $what",
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                    ),
                  ],
                ),
              ),
              const Gap(8),
              ValueListenableBuilder<double?>(
                valueListenable: notifier.progress,
                builder: (context, p, _) {
                  if (p != null && p < 1) {
                    return SizedBox(
                      width: 96,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text("${(p * 100).round()}%", style: theme.textTheme.labelMedium),
                          const Gap(4),
                          LinearProgressIndicator(value: p, minHeight: 4, borderRadius: BorderRadius.circular(2)),
                        ],
                      ),
                    );
                  }
                  return FilledButton(onPressed: () => notifier.openDownload(), child: const Text("Обновить"));
                },
              ),
              IconButton(
                tooltip: "Позже",
                onPressed: () => notifier.dismiss(info.version),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Подсказка под плашкой (ошибка загрузки / нужно разрешение на установку).
class UpdateHint extends ConsumerWidget {
  const UpdateHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.watch(oknoUpdateProvider.notifier);
    return ValueListenableBuilder<String?>(
      valueListenable: notifier.hint,
      builder: (context, h, _) {
        if (h == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
          child: Text(h, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        );
      },
    );
  }
}

/// Строка в настройках: «Оплата и продление» — открывает Telegram-бот сразу на экране оплаты
/// (звёзды Telegram / TON / карта). Бот и звёзды работают в Telegram на любой платформе.
class PayInBotTile extends StatelessWidget {
  const PayInBotTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.payments_outlined),
      title: const Text("Оплата и продление"),
      subtitle: const Text("в Telegram-боте: звёзды Telegram, TON, карта · откроется Telegram"),
      trailing: const Icon(Icons.open_in_new_rounded, size: 18),
      onTap: () => UriUtils.tryLaunch(Uri.parse("https://t.me/OKHO_VPN_BOT?start=pay")),
    );
  }
}

/// Строка в настройках: текущая версия, результат последней проверки, кнопка «Проверить».
class UpdateSettingsTile extends ConsumerWidget {
  const UpdateSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(oknoUpdateProvider);
    final notifier = ref.read(oknoUpdateProvider.notifier);
    final info = st.valueOrNull;
    final current = ref.watch(appInfoProvider).valueOrNull?.version ?? "";
    final String subtitle;
    if (st.isLoading) {
      subtitle = "проверяю…";
    } else if (st.hasError && info == null) {
      subtitle = "не удалось проверить — нет связи с GitHub";
    } else if (info == null) {
      subtitle = "версия $current · проверка при запуске и каждые 12 часов";
    } else if (info.isNewer) {
      subtitle = "доступна ${info.version}, у вас ${info.current} — нажмите, чтобы обновить";
    } else {
      subtitle = "версия $current — последняя · проверка каждые 12 часов";
    }
    return ListTile(
      leading: Icon(info?.isNewer == true ? Icons.system_update_alt_rounded : Icons.verified_rounded),
      title: const Text("Обновления"),
      subtitle: Text(subtitle),
      trailing: st.isLoading
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(onPressed: () => notifier.check(manual: true), child: const Text("Проверить")),
      onTap: info?.isNewer == true ? () => notifier.openDownload() : () => notifier.check(manual: true),
    );
  }
}
