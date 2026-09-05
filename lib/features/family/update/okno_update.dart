import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
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
  Future<bool> openDownload() async {
    final info = state.valueOrNull;
    if (info == null) return false;
    return UriUtils.tryLaunch(Uri.parse(info.downloadUrl));
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
            ? "Скачается файл установки — откройте его и подтвердите обновление."
            : "Скачается установщик — запустите его поверх текущей версии.";
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
              FilledButton(onPressed: () => notifier.openDownload(), child: const Text("Обновить")),
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
