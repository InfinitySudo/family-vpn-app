import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Окно: отчёт о сбое (все платформы).
///
/// Зачем: «нажал кнопку — приложение закрылось» у двух людей, а логов нет и
/// эмулятора нет. Теперь:
///  - ошибки Dart (FlutterError, PlatformDispatcher, зона) пишутся в
///    `<appSupport>/okno_crash.log`; на Android туда же пишет нативный
///    обработчик (Application.kt), так что Kotlin-падения тоже видны;
///  - при каждом «подключить» ставится метка `okno_session.txt`, при исходе
///    (подключились / отключились) снимается. Если при запуске метка стоит —
///    прошлый раз процесс умер посреди подключения (в т.ч. нативный SIGSEGV
///    ядра, который никто не ловит) → это тоже повод для отчёта;
///  - отчёт = версия, ОС, crash-лог, метка, хвосты app.log/box.log и
///    stderr.log/stderr2.log (туда Go-ядро пишет panic) → POST на Ригу
///    (/okno/crash), Артёму приходит в TG. Отправляется само, плашка на
///    главном экране говорит «отчёт отправлен».
class OknoCrash {
  static Directory? _dir;
  static Directory? _workingDir;
  static File? get _crashFile => _dir == null ? null : File("${_dir!.path}/okno_crash.log");
  static File? get _sessionFile => _dir == null ? null : File("${_dir!.path}/okno_session.txt");

  /// Ставится до bootstrap: ловим всё, что упадёт дальше.
  static Future<void> install() async {
    try {
      _dir = await getApplicationSupportDirectory();
    } catch (_) {
      return;
    }
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      _record("flutter", details.exceptionAsString(), details.stack?.toString() ?? "");
      prevFlutter?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _record("dart", error.toString(), stack.toString());
      return false;
    };
  }

  static void setWorkingDir(Directory d) => _workingDir = d;

  static void _record(String kind, String error, String stack) {
    final f = _crashFile;
    if (f == null) return;
    try {
      final entry = "\n=== $kind ${DateTime.now().toIso8601String()} ===\n$error\n$stack\n";
      f.writeAsStringSync(entry, mode: FileMode.append, flush: true);
      // не даём файлу расти бесконечно
      if (f.lengthSync() > 128 * 1024) {
        final s = f.readAsStringSync();
        f.writeAsStringSync(s.substring(s.length - 96 * 1024), flush: true);
      }
    } catch (_) {}
  }

  /// Ошибка зоны (runZonedGuarded в main).
  static void onZoneError(Object error, StackTrace stack) => _record("zone", error.toString(), stack.toString());

  /// Метка «сейчас подключаемся» — пусто = снять.
  static void mark(String what) {
    final f = _sessionFile;
    if (f == null) return;
    try {
      if (what.isEmpty) {
        if (f.existsSync()) f.deleteSync();
      } else {
        f.writeAsStringSync("$what ${DateTime.now().toIso8601String()}", flush: true);
      }
    } catch (_) {}
  }

  /// Есть ли что отправлять: crash-лог или зависшая метка прошлой сессии.
  static ({bool crash, String session}) pending() {
    final c = _crashFile;
    final s = _sessionFile;
    final hasCrash = c != null && c.existsSync() && c.lengthSync() > 0;
    final session = (s != null && s.existsSync()) ? s.readAsStringSync().trim() : "";
    return (crash: hasCrash, session: session);
  }

  static String _tail(File f, [int lines = 250]) {
    try {
      if (!f.existsSync()) return "";
      final all = f.readAsLinesSync();
      return all.sublist(all.length > lines ? all.length - lines : 0).join("\n");
    } catch (e) {
      return "(не прочитать: $e)";
    }
  }

  static const _endpoints = [
    "http://95.182.90.237:2097/okno/crash",
    "http://217.60.2.82:2097/okno/crash",
  ];

  /// Собрать и отправить. true — ушло (файлы очищены).
  static Future<bool> send({required String appVersion, String note = ""}) async {
    final p = pending();
    if (!p.crash && p.session.isEmpty && note.isEmpty) return false;
    final wd = _workingDir ?? _dir;
    final report = <String, dynamic>{
      "app": appVersion,
      "platform": Platform.operatingSystem,
      "os": Platform.operatingSystemVersion,
      "locale": Platform.localeName,
      "time": DateTime.now().toIso8601String(),
      "note": note,
      "session": p.session,
      "crash": p.crash ? _tail(_crashFile!, 400) : "",
      "app_log": wd == null ? "" : _tail(File("${wd.path}/app.log")),
      "box_log": wd == null ? "" : _tail(File("${wd.path}/box.log")),
      "stderr": wd == null ? "" : _tail(File("${wd.path}/stderr.log"), 120),
      "stderr2": wd == null ? "" : _tail(File("${wd.path}/stderr2.log"), 120),
    };
    final body = utf8.encode(jsonEncode(report));
    for (final url in _endpoints) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        final req = await client.postUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
        req.headers.contentType = ContentType.json;
        req.add(body);
        final resp = await req.close().timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          try { _crashFile?.deleteSync(); } catch (_) {}
          mark("");
          Logger.bootstrap.info("okno crash: report sent via $url");
          return true;
        }
      } catch (e) {
        Logger.bootstrap.warning("okno crash: $url failed: $e");
      } finally {
        client.close(force: true);
      }
    }
    return false;
  }
}

/// Состояние плашки: null — нечего показывать; true — отправлен; false — не удалось.
final oknoCrashReportProvider = FutureProvider<bool?>((ref) async {
  final p = OknoCrash.pending();
  if (!p.crash && p.session.isEmpty) return null;
  final version = (await ref.read(appInfoProvider.future)).version;
  return OknoCrash.send(appVersion: version);
});

class CrashReportBanner extends ConsumerWidget {
  const CrashReportBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(oknoCrashReportProvider);
    final v = st.valueOrNull;
    if (v == null && !st.isLoading) return const SizedBox.shrink();
    if (st.isLoading && !OknoCrash.pending().crash && OknoCrash.pending().session.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final text = st.isLoading
        ? "Прошлый раз приложение закрылось с ошибкой — отправляю отчёт…"
        : v == true
            ? "Прошлый раз приложение закрылось с ошибкой. Отчёт отправлен разработчику, спасибо."
            : "Прошлый раз приложение закрылось с ошибкой. Отчёт отправить не удалось — попробую при следующем запуске.";
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Icon(Icons.bug_report_outlined, color: theme.colorScheme.onSurfaceVariant),
              const Gap(10),
              Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
            ],
          ),
        ),
      ),
    );
  }
}
