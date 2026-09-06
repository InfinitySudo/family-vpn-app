import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/family/family_profile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Окно: отчёт о сбое (все платформы).
///
/// Зачем: «нажал кнопку — приложение закрылось» у двух людей, а логов нет и
/// эмулятора нет. Теперь:
///  - ошибки Dart (FlutterError, PlatformDispatcher, зона) пишутся в
///    `<appSupport>/okno_crash.log`; на Android туда же пишет нативный
///    обработчик (Application.kt), так что Kotlin-падения тоже видны;
///  - метка `okno_session.txt`: «connecting» при нажатии, «connected» когда
///    подключились; снимается ТОЛЬКО при отключении кнопкой или штатном выходе.
///    Если при запуске метка стоит — прошлый процесс умер, пока Окно работало
///    (нативное падение ядра или система убила приложение) → отчёт с logcat;
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

  /// Android: logcat собственного процесса (свой UID виден без прав; строки прошлого процесса
  /// с тем же UID тоже — там «FATAL EXCEPTION», «Process … has died», причины убийства).
  static Future<String> _logcat() async {
    if (!Platform.isAndroid) return "";
    try {
      final r = await Process.run("logcat", ["-d", "-v", "time", "-t", "400"]).timeout(const Duration(seconds: 8));
      final out = (r.stdout as String? ?? "");
      return out.length > 40000 ? out.substring(out.length - 40000) : out;
    } catch (e) {
      return "(logcat: $e)";
    }
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

  /// Куда слать: агрегатор/зеркала подписки (`…/okno/<id>` → `…/okno/crash`), сохранённые и зашитые.
  static Future<List<String>> _endpoints() async {
    final out = <String>[];
    for (final u in await familySubscriptionCandidates()) {
      final i = u.indexOf("/okno/");
      if (i < 0) continue;
      final e = "${u.substring(0, i)}/okno/crash";
      if (!out.contains(e)) out.add(e);
    }
    return out;
  }

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
      "logcat": await _logcat(),
    };
    final body = utf8.encode(jsonEncode(report));
    for (final url in await _endpoints()) {
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
  var p = OknoCrash.pending();
  if (!p.crash && p.session.isEmpty) return null;
  if (!p.crash && p.session.startsWith("connected")) {
    // Метка «был подключён» без crash-лога: возможно, VPN-служба жива, а систему просто
    // закрыла экран приложения (это норма). Ждём статус ядра: подключено → не сбой.
    await Future<void>.delayed(const Duration(seconds: 6));
    final st = ref.read(connectionNotifierProvider).valueOrNull;
    if (st != null && st.isConnected) {
      OknoCrash.mark("connected");
      return null;
    }
    p = OknoCrash.pending();
    if (!p.crash && p.session.isEmpty) return null;
  }
  final version = (await ref.read(appInfoProvider.future)).version;
  return OknoCrash.send(appVersion: version);
});

/// Ручной отчёт из настроек и автоматический при неудачном подключении (не чаще раза в 10 мин).
DateTime? _lastAutoReport;

Future<bool> oknoSendReport(WidgetRef ref, {required String note, bool auto = false}) async {
  if (auto) {
    final now = DateTime.now();
    if (_lastAutoReport != null && now.difference(_lastAutoReport!) < const Duration(minutes: 10)) return false;
    _lastAutoReport = now;
  }
  final version = (await ref.read(appInfoProvider.future)).version;
  return OknoCrash.send(appVersion: version, note: note);
}

/// Строка в настройках: «Сообщить о проблеме» — логи уходят разработчику одним нажатием.
class ReportProblemTile extends ConsumerStatefulWidget {
  const ReportProblemTile({super.key});

  @override
  ConsumerState<ReportProblemTile> createState() => _ReportProblemTileState();
}

class _ReportProblemTileState extends ConsumerState<ReportProblemTile> {
  bool busy = false;
  String? result;

  Future<void> _send() async {
    setState(() { busy = true; result = null; });
    final ok = await oknoSendReport(ref, note: "ручной отчёт из настроек");
    if (!mounted) return;
    setState(() {
      busy = false;
      result = ok ? "отправлено, спасибо" : "не удалось отправить — проверьте связь и попробуйте ещё раз";
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.outgoing_mail),
      title: const Text("Сообщить о проблеме"),
      subtitle: Text(result ?? "логи приложения уйдут разработчику одним нажатием"),
      trailing: busy
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.send_rounded),
      onTap: busy ? null : _send,
    );
  }
}

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
