import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';

/// Окно: сторож против чужих VPN.
///
/// На телефоне может работать только один VPN-туннель. Родные ставят Окно, но забывают
/// выключить старый клиент (Happ, v2rayNG, Hiddify…) — тот с автоподключением перехватывает
/// туннель, Окно «выкидывает», и жалоба «ваш VPN не работает». Здесь:
///  - проверка ПЕРЕД подключением (чужой туннель активен / чужое приложение назначено
///    «постоянным VPN») → экран «Мешает другой VPN» с кнопками вместо непонятной ошибки;
///  - событие перехвата от нативной службы (Android onRevoke) → тот же экран + кнопка
///    «Подключить Окно»;
///  - подсказка сделать Окно «постоянным VPN» — единственный способ, при котором система
///    сама не даст другим приложениям перехватывать туннель (100% из 100).
final _log = Loggy("OknoVpnGuard");

class OknoVpnApp {
  const OknoVpnApp({required this.package, required this.label});
  final String package;
  final String label;
}

class OknoForeignVpnInfo {
  const OknoForeignVpnInfo({
    required this.active,
    required this.apps,
    this.alwaysOnPackage,
    this.alwaysOnSelf = false,
    this.alwaysOnForeign = false,
    this.interfaces = const [],
  });

  /// Сетевые интерфейсы чужого VPN (utun/tun/wg/ppp…) — iPhone, Mac, Windows, Linux.
  final List<String> interfaces;

  /// Прямо сейчас в системе есть чужой VPN-туннель (наша служба не запущена).
  final bool active;

  /// Установленные VPN-клиенты кроме Окна (Android).
  final List<OknoVpnApp> apps;

  /// Пакет, назначенный «постоянным VPN» в настройках Android (best-effort, может быть null).
  final String? alwaysOnPackage;
  final bool alwaysOnSelf;
  final bool alwaysOnForeign;

  /// Что-то мешает подключиться прямо сейчас.
  bool get blocks => active || alwaysOnForeign;

  String? get alwaysOnForeignLabel {
    if (!alwaysOnForeign) return null;
    for (final a in apps) {
      if (a.package == alwaysOnPackage) return a.label;
    }
    return alwaysOnPackage;
  }

  static const empty = OknoForeignVpnInfo(active: false, apps: []);

  factory OknoForeignVpnInfo.fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) return empty;
    final apps = <OknoVpnApp>[];
    final rawApps = m["apps"];
    if (rawApps is List) {
      for (final e in rawApps) {
        if (e is Map) {
          apps.add(OknoVpnApp(package: "${e["package"] ?? ""}", label: "${e["label"] ?? e["package"] ?? ""}"));
        }
      }
    }
    final rawIf = m["interfaces"];
    return OknoForeignVpnInfo(
      active: m["active"] == true,
      apps: apps,
      alwaysOnPackage: m["always_on_package"] as String?,
      alwaysOnSelf: m["always_on_self"] == true,
      alwaysOnForeign: m["always_on_foreign"] == true,
      interfaces: rawIf is List ? [for (final e in rawIf) "$e"] : const [],
    );
  }
}

/// Причина показа экрана — от неё зависит текст.
enum OknoGuardReason { preflight, revoked, setup }

/// Маркер для ConnectionFailure.unexpected(error): подключение остановлено сторожем,
/// показать экран вместо общего диалога ошибки.
class OknoForeignVpnBlock {
  const OknoForeignVpnBlock(this.info);
  final OknoForeignVpnInfo info;

  @override
  String toString() => "foreign VPN blocks connection (active=${info.active}, alwaysOnForeign=${info.alwaysOnForeign})";
}

class OknoVpnGuard {
  static const _android = MethodChannel("com.hiddify.app/okno");
  static const _androidEvents = EventChannel("com.hiddify.app/okno.events", JSONMethodCodec());

  // iOS: отдельного Swift-файла нет (иначе править pbxproj) — метод живёт в общем канале.
  static const _iosMethod = MethodChannel("com.hiddify.app/method");

  static bool get supported => true;

  /// «Подключить всё равно»: следующий preflight пропускаем (iPhone/Mac: другой VPN отключится сам).
  static bool skipNextPreflight = false;

  // tailscale — mesh-сеть, с Окном не конфликтует, поэтому не считаем
  static final RegExp _vpnIface = RegExp(r"^(utun|tun|tap|ppp|ipsec|wg|proton|nord|surfshark|expressvpn|Mullvad|OpenVPN|WireGuard|Hiddify|sing)", caseSensitive: false);

  /// Чужой VPN по сетевым интерфейсам (когда наше ядро остановлено). Системные utun на
  /// Apple всегда есть, но без адресов (или только link-local) — поэтому смотрим адреса.
  static Future<List<String>> foreignInterfaces() async {
    try {
      final list = await NetworkInterface.list(includeLinkLocal: false, includeLoopback: false)
          .timeout(const Duration(seconds: 3));
      final out = <String>[];
      for (final i in list) {
        if (!_vpnIface.hasMatch(i.name)) continue;
        final real = i.addresses.where((a) => !a.isLinkLocal && !a.isLoopback && !a.isMulticast).toList();
        if (real.isEmpty) continue;
        out.add("${i.name} (${real.first.address})");
      }
      return out;
    } catch (e) {
      _log.debug("foreignInterfaces failed: $e");
      return const [];
    }
  }

  /// Что мешает подключению. Никогда не бросает — при любой ошибке «ничего не мешает».
  static Future<OknoForeignVpnInfo> check() async {
    if (!Platform.isAndroid) {
      final ifaces = await foreignInterfaces();
      return OknoForeignVpnInfo(active: ifaces.isNotEmpty, apps: const [], interfaces: ifaces);
    }
    try {
      final res = await _android.invokeMethod<dynamic>("foreign_vpn").timeout(const Duration(seconds: 3));
      return OknoForeignVpnInfo.fromMap(res is Map ? res : null);
    } on MissingPluginException {
      return OknoForeignVpnInfo.empty;
    } catch (e) {
      _log.warning("foreign vpn check failed: $e");
      return OknoForeignVpnInfo.empty;
    }
  }

  /// Проверка перед подключением: чужой туннель может ещё пару сотен мс висеть после остановки
  /// нашей службы — перепроверяем, прежде чем блокировать.
  static Future<OknoForeignVpnInfo?> preflightBlock() async {
    if (skipNextPreflight) {
      skipNextPreflight = false;
      return null;
    }
    // iPhone: система держит одну VPN-конфигурацию — при подключении Окна другой VPN
    // выключается сам, предупреждать не о чем (решение Артёма 06.09).
    if (Platform.isIOS) return null;
    if (Platform.isAndroid) {
      var info = await check();
      if (!info.blocks) return null;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      info = await check();
      return info.blocks ? info : null;
    }
    // iPhone / Mac / Windows / Linux: по интерфейсам, с перепроверкой (наш туннель мог ещё не исчезнуть)
    var ifaces = await foreignInterfaces();
    if (ifaces.isEmpty) return null;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    ifaces = await foreignInterfaces();
    if (ifaces.isEmpty) return null;
    return OknoForeignVpnInfo(active: true, apps: const [], interfaces: ifaces);
  }

  static Stream<Map<dynamic, dynamic>> revokedEvents() {
    if (!Platform.isAndroid) return const Stream.empty();
    return _androidEvents.receiveBroadcastStream().where((e) => e is Map).map((e) => e as Map);
  }

  static Future<void> consumeRevoked() async {
    if (!Platform.isAndroid) return;
    try {
      await _android.invokeMethod("consume_revoked");
    } catch (_) {}
  }

  static Future<bool> openVpnSettings() => _call("open_vpn_settings");
  static Future<bool> openApp(String pkg) => _call("open_app", {"package": pkg});
  static Future<bool> openAppSettings(String pkg) => _call("open_app_settings", {"package": pkg});
  static Future<bool> uninstall(String pkg) => _call("uninstall", {"package": pkg});

  static Future<bool> _call(String method, [Map<String, dynamic>? args]) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _android.invokeMethod<bool>(method, args) ?? false;
    } catch (e) {
      _log.warning("$method failed: $e");
      return false;
    }
  }
}

/// Сигнал «покажи экран» из ConnectionNotifier (у него нет BuildContext).
final oknoForeignVpnSignal = StateProvider<OknoForeignVpnBlock?>((ref) => null);

/// События перехвата от нативной службы.
final oknoRevokedEventsProvider = StreamProvider<Map<dynamic, dynamic>>((ref) => OknoVpnGuard.revokedEvents());

/// Текущее состояние (для строки в настройках); обновляется при каждом показе экрана.
final oknoForeignVpnInfoProvider = FutureProvider.autoDispose<OknoForeignVpnInfo>((ref) => OknoVpnGuard.check());

/// Обёртка главного экрана: слушает сигнал сторожа и события перехвата, показывает нижний лист.
class OknoVpnGuardListener extends ConsumerWidget {
  const OknoVpnGuardListener({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(oknoForeignVpnSignal, (prev, next) {
      if (next == null) return;
      ref.read(oknoForeignVpnSignal.notifier).state = null;
      showForeignVpnSheet(context, reason: OknoGuardReason.preflight, info: next.info);
    });
    ref.listen(oknoRevokedEventsProvider, (prev, next) {
      final ev = next.valueOrNull;
      if (ev == null || ev["event"] != "revoked") return;
      OknoVpnGuard.consumeRevoked();
      showForeignVpnSheet(context, reason: OknoGuardReason.revoked, info: OknoForeignVpnInfo.fromMap(ev));
    });
    return child;
  }
}

bool _sheetOpen = false;

Future<void> showForeignVpnSheet(BuildContext context, {required OknoGuardReason reason, OknoForeignVpnInfo? info}) async {
  if (_sheetOpen) return;
  _sheetOpen = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => _ForeignVpnSheet(reason: reason, initial: info),
    );
  } finally {
    _sheetOpen = false;
  }
}

class _ForeignVpnSheet extends ConsumerStatefulWidget {
  const _ForeignVpnSheet({required this.reason, this.initial});
  final OknoGuardReason reason;
  final OknoForeignVpnInfo? initial;

  @override
  ConsumerState<_ForeignVpnSheet> createState() => _ForeignVpnSheetState();
}

class _ForeignVpnSheetState extends ConsumerState<_ForeignVpnSheet> with WidgetsBindingObserver {
  late OknoForeignVpnInfo info = widget.initial ?? OknoForeignVpnInfo.empty;
  bool refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // вернулись из настроек / после удаления — перечитываем состояние
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (refreshing) return;
    setState(() => refreshing = true);
    final fresh = await OknoVpnGuard.check();
    if (!mounted) return;
    setState(() {
      info = fresh;
      refreshing = false;
    });
    ref.invalidate(oknoForeignVpnInfoProvider);
  }

  Future<void> _connect({bool force = false}) async {
    Navigator.of(context).pop();
    if (force) OknoVpnGuard.skipNextPreflight = true;
    final st = ref.read(connectionNotifierProvider);
    final notifier = ref.read(connectionNotifierProvider.notifier);
    // toggleConnection выставляет startedByUser и подключает только из Disconnected/ошибки;
    // если уже подключены — ничего не трогаем
    switch (st) {
      case AsyncError():
      case AsyncData(value: Disconnected()):
        await notifier.toggleConnection();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isAndroid = Platform.isAndroid;
    final foreignAlwaysOn = info.alwaysOnForeignLabel;

    final String title;
    final String intro;
    switch (widget.reason) {
      case OknoGuardReason.revoked:
        title = "Окно отключил другой VPN";
        intro = "Другое VPN-приложение только что перехватило соединение. "
            "На телефоне может работать только один VPN — пока включён чужой, Окно работать не будет.";
      case OknoGuardReason.preflight:
        title = isAndroid ? "Мешает другой VPN" : "Сейчас включён другой VPN";
        intro = foreignAlwaysOn != null
            ? "В настройках Android «постоянным VPN» назначено приложение «$foreignAlwaysOn». "
                "Пока так, система не даст Окну подключиться."
            : isAndroid
                ? "Сейчас включён другой VPN. На телефоне может работать только один — выключите его, "
                    "и Окно подключится."
                : Platform.isIOS
                    ? "iPhone держит только один VPN: при подключении Окна другой отключится сам. "
                        "Если он потом включается обратно сам (у него стоит «Подключаться по запросу»), "
                        "Окно будет выбивать — выключите это в Настройки → VPN → (i) у того VPN, или удалите его."
                    : "Два VPN одновременно мешают друг другу: часть трафика пойдёт мимо Окна или интернет пропадёт. "
                        "Лучше выключить другой VPN и подключить Окно.";
      case OknoGuardReason.setup:
        title = "Постоянный VPN";
        intro = "Если сделать Окно «постоянным VPN», телефон сам будет поднимать его при включении, "
            "а другие VPN-приложения не смогут перехватывать соединение.";
    }

    final showBlocker = widget.reason != OknoGuardReason.setup;
    final canConnect = !info.blocks;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                widget.reason == OknoGuardReason.setup ? Icons.verified_user_rounded : Icons.warning_amber_rounded,
                color: widget.reason == OknoGuardReason.setup ? cs.primary : cs.error,
                size: 30,
              ),
              const Gap(10),
              Expanded(child: Text(title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
              if (refreshing) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const Gap(10),
          Text(intro, style: theme.textTheme.bodyLarge),
          if (showBlocker) ...[
            const Gap(16),
            if (isAndroid && info.apps.isNotEmpty) ...[
              Text(
                "VPN-приложения на телефоне",
                style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant),
              ),
              const Gap(6),
              for (final a in info.apps) _AppRow(app: a, isAlwaysOn: a.package == info.alwaysOnPackage),
              const Gap(6),
              Text(
                "«Открыть» — выключите VPN внутри приложения. «Удалить» — надёжнее всего: "
                "старое приложение больше не нужно.",
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ] else if (isAndroid) ...[
              Text(
                "Выключите VPN в другом приложении или в Настройках Android → Подключения → VPN.",
                style: theme.textTheme.bodyMedium,
              ),
            ] else ...[
              if (info.interfaces.isNotEmpty)
                Text(
                  "Найдено: ${info.interfaces.join(", ")}",
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              const Gap(6),
              Text(
                Platform.isIOS
                    ? "Где выключить: Настройки → VPN (или Основные → VPN и управление устройством)."
                    : Platform.isMacOS
                        ? "Где выключить: Системные настройки → VPN, либо в самом приложении другого VPN."
                        : "Выключите другой VPN в его приложении или в настройках сети.",
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (isAndroid && foreignAlwaysOn != null) ...[
              const Gap(12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "У приложения «$foreignAlwaysOn» включён «Постоянный VPN». Снимите его: "
                  "Настройки VPN → шестерёнка у «$foreignAlwaysOn» → выключить «Постоянный VPN».",
                  style: theme.textTheme.bodyMedium?.copyWith(color: cs.onErrorContainer),
                ),
              ),
            ],
          ],
          if (isAndroid) ...[
            const Gap(18),
            _AlwaysOnCard(info: info, emphasized: widget.reason == OknoGuardReason.setup),
          ],
          const Gap(18),
          if (showBlocker)
            FilledButton.icon(
              onPressed: canConnect ? _connect : null,
              icon: const Icon(Icons.power_settings_new_rounded),
              label: Text(canConnect ? "Подключить Окно" : "Сначала выключите другой VPN"),
            ),
          if (showBlocker && !canConnect && !isAndroid) ...[
            const Gap(8),
            OutlinedButton.icon(
              onPressed: () => _connect(force: true),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(Platform.isIOS ? "Подключить всё равно (другой отключится)" : "Подключить всё равно"),
            ),
          ],
          if (showBlocker) const Gap(8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text("Проверить снова"),
                ),
              ),
              const Gap(8),
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("Закрыть"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.isAlwaysOn});
  final OknoVpnApp app;
  final bool isAlwaysOn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.vpn_key_rounded, color: isAlwaysOn ? cs.error : cs.onSurfaceVariant),
            const Gap(10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.label, style: theme.textTheme.titleSmall),
                  if (isAlwaysOn)
                    Text("назначен «постоянным VPN»", style: theme.textTheme.bodySmall?.copyWith(color: cs.error)),
                ],
              ),
            ),
            TextButton(onPressed: () => OknoVpnGuard.openApp(app.package), child: const Text("Открыть")),
            FilledButton.tonal(
              onPressed: () => OknoVpnGuard.uninstall(app.package),
              style: FilledButton.styleFrom(foregroundColor: cs.error),
              child: const Text("Удалить"),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlwaysOnCard extends StatelessWidget {
  const _AlwaysOnCard({required this.info, required this.emphasized});
  final OknoForeignVpnInfo info;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final done = info.alwaysOnSelf;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: done ? cs.primaryContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: emphasized && !done ? Border.all(color: cs.primary) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(done ? Icons.check_circle_rounded : Icons.shield_outlined, color: done ? cs.primary : cs.onSurfaceVariant),
              const Gap(8),
              Expanded(
                child: Text(
                  done ? "Окно — постоянный VPN ✓" : "Чтобы такого больше не повторялось",
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const Gap(6),
          Text(
            done
                ? "Телефон сам поднимает Окно при включении, а другие VPN-приложения не смогут перехватить соединение."
                : "Сделайте Окно «постоянным VPN» — тогда другие VPN-приложения не смогут его перехватывать:\n"
                    "1. Нажмите «Настройки VPN».\n"
                    "2. Шестерёнка ⚙ рядом с «Окно».\n"
                    "3. Включите «Постоянный VPN» (Always-on).",
            style: theme.textTheme.bodyMedium,
          ),
          if (!done) ...[
            const Gap(10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: OknoVpnGuard.openVpnSettings,
                icon: const Icon(Icons.settings_rounded),
                label: const Text("Настройки VPN"),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Строка в настройках: состояние «постоянного VPN» (Android).
class AlwaysOnVpnTile extends ConsumerWidget {
  const AlwaysOnVpnTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final info = ref.watch(oknoForeignVpnInfoProvider).valueOrNull;
    final cs = Theme.of(context).colorScheme;
    final String subtitle;
    IconData icon = Icons.shield_outlined;
    Color? color;
    if (info == null) {
      subtitle = "проверяю…";
    } else if (info.alwaysOnSelf) {
      subtitle = "включён — другие VPN не перехватят соединение";
      icon = Icons.verified_user_rounded;
      color = cs.primary;
    } else if (info.alwaysOnForeign) {
      subtitle = "назначено другое приложение: «${info.alwaysOnForeignLabel}» — Окно не подключится";
      icon = Icons.gpp_bad_rounded;
      color = cs.error;
    } else if (info.apps.isNotEmpty) {
      subtitle = "выключен · на телефоне ещё ${info.apps.length} VPN — могут выкидывать Окно";
      color = cs.error;
    } else {
      subtitle = "выключен · рекомендуем включить";
    }
    return ListTile(
      leading: Icon(icon, color: color),
      title: const Text("Постоянный VPN"),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showForeignVpnSheet(
        context,
        reason: (info?.blocks ?? false) ? OknoGuardReason.preflight : OknoGuardReason.setup,
        info: info,
      ),
    );
  }
}
