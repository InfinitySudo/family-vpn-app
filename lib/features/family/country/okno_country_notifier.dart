import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/family/country/okno_country.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Тег группы-селектора в конфиге Hiddify.
const String oknoSelectGroup = "select";

/// Сохранённая страна ("" — авто, ядро само берёт самый быстрый узел).
/// Хранится в SharedPreferences, переживает перезапуск и обновление приложения.
final oknoCountryPref = PreferencesNotifier.create<String, String>("okno_country", "");

/// Один узел подписки глазами экрана выбора страны.
class OknoServer {
  const OknoServer({
    required this.tag,
    required this.country,
    required this.delay,
    this.host = "",
    this.port = 0,
    this.isAuto = false,
    this.isSelected = false,
    this.groupSelectedTag = "",
  });

  final String tag;
  final String country;
  /// Задержка в мс: 0 — не измерена, ≥65000 — нет ответа.
  final int delay;
  final String host;
  final int port;
  /// Узел-группа «auto» (ядро само выбирает).
  final bool isAuto;
  final bool isSelected;
  /// Для группы «auto»: тег узла, который ядро выбрало сейчас.
  final String groupSelectedTag;

  String get label => serverLabelOfTag(tag);
}

/// Сводка по стране: её узлы, лучший пинг и выбрана ли она сейчас.
class OknoCountryStat {
  OknoCountryStat({required this.country, required this.servers});

  final OknoCountry country;
  final List<OknoServer> servers;

  /// Лучший измеренный пинг (0 — ничего не измерено, timeout — ни один не отвечает).
  int get bestDelay {
    var best = 0;
    var anyTimeout = false;
    for (final s in servers) {
      if (!isDelayKnown(s.delay)) continue;
      if (isDelayTimeout(s.delay)) {
        anyTimeout = true;
        continue;
      }
      if (best == 0 || s.delay < best) best = s.delay;
    }
    if (best == 0 && anyTimeout) return oknoDelayTimeout;
    return best;
  }

  bool get isSelected => servers.any((s) => s.isSelected);

  /// Порядок предпочтения узлов (см. [rankServers]).
  List<OknoServer> get ranked => rankServers(servers);
}

/// Ярус предпочтения узла: 0 — живой Reality (TCP), 1 — неизмеренный Reality,
/// 2 — живой HY2 (UDP), 3 — неизмеренный HY2, 4 — не отвечающие (Reality раньше HY2).
/// Reality впереди HY2 при любом пинге (решение Артёма 09.09): UDP из РФ душат,
/// и «быстрый» по пингу HY2 умирает посреди звонка.
int oknoServerTier(OknoServer s) {
  if (isDelayTimeout(s.delay)) return 4;
  final udp = isUdpProtocolTag(s.tag);
  final known = isDelayKnown(s.delay);
  if (!udp) return known ? 0 : 1;
  return known ? 2 : 3;
}

/// Порядок предпочтения: по ярусу [oknoServerTier], внутри яруса — по задержке.
List<OknoServer> rankServers(List<OknoServer> servers) {
  final out = [...servers];
  out.sort((a, b) {
    final r = oknoServerTier(a).compareTo(oknoServerTier(b));
    if (r != 0) return r;
    final u = (isUdpProtocolTag(a.tag) ? 1 : 0).compareTo(isUdpProtocolTag(b.tag) ? 1 : 0);
    if (u != 0) return u;
    return a.delay.compareTo(b.delay);
  });
  return out;
}

/// Итог для UI: страны + узел «авто» + источник задержек.
class OknoCountriesState {
  const OknoCountriesState({required this.countries, required this.auto, required this.live, this.selectedCountry = ""});

  final List<OknoCountryStat> countries;
  final OknoServer? auto;
  /// true — задержки от ядра через VPN (подключены); false — TCP-отклик серверов без VPN.
  final bool live;
  /// Страна выбранного сейчас узла ("" — авто/неизвестно).
  final String selectedCountry;

  OknoCountryStat? byCode(String code) {
    for (final c in countries) {
      if (c.country.code == code) return c;
    }
    return null;
  }
}

/// Группа-селектор от ядра, пока сервис запущен; null — не подключены.
final oknoGroupProvider = StreamProvider<OutboundGroup?>((ref) {
  final running = ref.watch(serviceRunningProvider);
  if (!running) return Stream.value(null);
  return ref.watch(proxyRepositoryProvider).watchProxies().map((e) => e.getOrElse((_) => null));
});

/// Узлы из файла конфига активного профиля: (tag, host, port). Нужны, чтобы
/// показать список стран и померить отклик ДО подключения.
final oknoConfigServersProvider = FutureProvider<List<OknoServer>>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return const [];
  final file = ref.watch(profilePathResolverProvider).file(profile.id);
  if (!await file.exists()) return const [];
  try {
    return parseServersFromConfig(await file.readAsString());
  } catch (e) {
    Logger.bootstrap.debug("okno country: config parse failed: $e");
    return const [];
  }
});

/// Разбор конфига sing-box (JSON) либо списка ссылок (в т.ч. base64) → узлы.
List<OknoServer> parseServersFromConfig(String content) {
  final out = <OknoServer>[];
  final trimmed = content.trim();
  if (trimmed.startsWith("{")) {
    final json = jsonDecode(trimmed) as Map<String, dynamic>;
    final outbounds = (json["outbounds"] as List?) ?? const [];
    for (final o in outbounds) {
      if (o is! Map) continue;
      final tag = (o["tag"] ?? "").toString();
      final host = (o["server"] ?? "").toString();
      final port = int.tryParse((o["server_port"] ?? "").toString()) ?? 0;
      if (host.isEmpty || tag.isEmpty) continue;
      final cc = countryCodeOfTag(tag);
      if (cc.isEmpty) continue;
      out.add(OknoServer(tag: tag, country: cc, delay: 0, host: host, port: port));
    }
    return out;
  }
  var text = trimmed;
  if (!text.contains("://")) {
    try {
      text = utf8.decode(base64.decode(base64.normalize(text)));
    } catch (_) {
      return out;
    }
  }
  for (final line in text.split(RegExp(r"[\r\n]+"))) {
    final uri = Uri.tryParse(line.trim());
    if (uri == null || uri.host.isEmpty) continue;
    final tag = Uri.decodeComponent(uri.fragment);
    final cc = countryCodeOfTag(tag);
    if (cc.isEmpty) continue;
    out.add(OknoServer(tag: tag, country: cc, delay: 0, host: uri.host, port: uri.port));
  }
  return out;
}

/// TCP-отклик серверов без VPN: время установления соединения до host:port.
/// Заблокированный в РФ адрес висит на SYN → 4 с и «нет ответа». Результат по тегу.
final oknoProbeProvider = FutureProvider<Map<String, int>>((ref) async {
  final servers = await ref.watch(oknoConfigServersProvider.future);
  final results = <String, int>{};
  await Future.wait(servers.map((s) async {
    results[s.tag] = await tcpProbe(s.host, s.port == 0 ? 443 : s.port);
  }));
  return results;
});

Future<int> tcpProbe(String host, int port, {Duration timeout = const Duration(seconds: 4)}) async {
  final sw = Stopwatch()..start();
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return sw.elapsedMilliseconds.clamp(1, oknoDelayTimeout - 1);
  } catch (_) {
    return oknoDelayTimeout;
  }
}

/// Собирает страны из данных ядра (подключены) или из конфига + TCP-пробы (нет).
final oknoCountriesProvider = Provider<AsyncValue<OknoCountriesState>>((ref) {
  final group = ref.watch(oknoGroupProvider);
  final g = group.valueOrNull;
  if (g != null) {
    final servers = <OknoServer>[];
    OknoServer? auto;
    for (final item in g.items) {
      if (item.isGroup) {
        auto = OknoServer(
          tag: item.tag,
          country: countryCodeOfTag(item.groupSelectedTag),
          delay: item.urlTestDelay,
          isAuto: true,
          isSelected: g.selected == item.tag,
          groupSelectedTag: item.groupSelectedTag,
        );
        continue;
      }
      final cc = countryCodeOfOutbound(item);
      if (cc.isEmpty) continue;
      servers.add(OknoServer(tag: item.tag, country: cc, delay: item.urlTestDelay, isSelected: g.selected == item.tag));
    }
    var selectedCountry = "";
    for (final s in servers) {
      if (s.isSelected) selectedCountry = s.country;
    }
    if (selectedCountry.isEmpty && auto != null && auto.isSelected) selectedCountry = auto.country;
    return AsyncData(OknoCountriesState(countries: _groupByCountry(servers), auto: auto, live: true, selectedCountry: selectedCountry));
  }
  // не подключены — конфиг + проба
  final config = ref.watch(oknoConfigServersProvider);
  final probe = ref.watch(oknoProbeProvider);
  return config.whenData((servers) {
    final delays = probe.valueOrNull ?? const <String, int>{};
    final withDelay = [
      for (final s in servers)
        OknoServer(tag: s.tag, country: s.country, delay: delays[s.tag] ?? 0, host: s.host, port: s.port),
    ];
    return OknoCountriesState(countries: _groupByCountry(withDelay), auto: null, live: false);
  });
});

List<OknoCountryStat> _groupByCountry(List<OknoServer> servers) {
  final map = <String, List<OknoServer>>{};
  for (final s in servers) {
    map.putIfAbsent(s.country, () => []).add(s);
  }
  final stats = [for (final e in map.entries) OknoCountryStat(country: OknoCountry.byCode(e.key), servers: e.value)];
  stats.sort((a, b) => a.country.name.compareTo(b.country.name));
  return stats;
}

/// Действия пользователя на экране выбора страны.
class OknoCountryActions {
  OknoCountryActions(this.ref);
  final Ref ref;

  /// Выбрать страну ("" — авто): сохранить и, если подключены, сразу применить.
  Future<void> choose(String code) async {
    await ref.read(oknoCountryPref.notifier).update(code);
    final g = ref.read(oknoGroupProvider).valueOrNull;
    if (g == null) return;
    if (code.isEmpty) {
      final auto = g.items.where((i) => i.isGroup).firstOrNull;
      if (auto != null && g.selected != auto.tag) {
        await ref.read(proxyRepositoryProvider).selectProxy(g.tag, auto.tag).run();
      }
      return;
    }
    await ref.read(oknoCountryGuardProvider).apply(force: true);
  }

  /// Перемерить пинг: через VPN — url-тест ядра, без VPN — TCP-проба.
  Future<void> refreshPing() async {
    final g = ref.read(oknoGroupProvider).valueOrNull;
    if (g != null) {
      await ref.read(proxyRepositoryProvider).urlTest(g.tag).run();
    } else {
      ref.invalidate(oknoProbeProvider);
    }
  }
}

final oknoCountryActionsProvider = Provider((ref) => OknoCountryActions(ref));

/// Сторож страны: пока сервис запущен, следит, чтобы выбранный узел был из
/// сохранённой страны и по возможности на Reality (TCP). Переключает ТОЛЬКО если
/// текущий узел из другой страны, перестал отвечать или это HY2 при живом Reality —
/// иначе не трогает (стабильность важнее пары мс: у AI-сервисов сессия привязана
/// к адресу).
///
/// В режиме «авто» (страна не выбрана) ядро само берёт самый быстрый узел, и это
/// часто HY2. Тогда сторож переводит на лучший Reality (любой страны); если Reality
/// не отвечает — возвращается к HY2.
class OknoCountryGuard {
  OknoCountryGuard(this.ref) {
    ref.listen<AsyncValue<OutboundGroup?>>(oknoGroupProvider, (_, next) {
      final g = next.valueOrNull;
      if (g == null) {
        _appliedFor = null;
        return;
      }
      unawaited(apply());
    });
  }

  final Ref ref;
  String? _appliedFor;
  DateTime _lastSwitch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProbe = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> apply({bool force = false}) async {
    final pref = ref.read(oknoCountryPref);
    final g = ref.read(oknoGroupProvider).valueOrNull;
    if (g == null) return;
    final state = ref.read(oknoCountriesProvider).valueOrNull;
    if (state == null) return;

    final List<OknoServer> candidates;
    if (pref.isEmpty) {
      candidates = [for (final c in state.countries) ...c.servers];
    } else {
      final stat = state.byCode(pref);
      if (stat == null || stat.servers.isEmpty) return; // такой страны в подписке нет — не трогаем
      candidates = stat.servers;
    }
    if (candidates.isEmpty) return;

    var current = candidates.where((s) => s.isSelected).firstOrNull;
    // «авто»: выбрана группа ядра — смотрим, какой узел она взяла
    final auto = state.auto;
    final viaAuto = pref.isEmpty && current == null && auto != null && auto.isSelected;
    if (viaAuto) {
      current = candidates.where((s) => s.tag == auto.groupSelectedTag).firstOrNull;
      // ядро само на Reality (или ещё не выбрало) — не мешаем
      if (current == null || !isUdpProtocolTag(current.tag)) return;
    }
    final ranked = rankServers(candidates);
    final best = ranked.first;
    final bestAlive = isDelayKnown(best.delay) && !isDelayTimeout(best.delay);
    final currentOk = current != null && !isDelayTimeout(current.delay);
    // текущий — HY2, а лучший Reality жив → уходим с UDP. Если Reality ещё не
    // измерен — не прыгаем вслепую, просим ядро померить (не чаще раза в 30 с).
    final onUdp = currentOk && isUdpProtocolTag(current.tag) && !isUdpProtocolTag(best.tag);
    final upgrade = onUdp && bestAlive;
    if (onUdp && !bestAlive && !isDelayKnown(best.delay) && DateTime.now().difference(_lastProbe) > const Duration(seconds: 30)) {
      _lastProbe = DateTime.now();
      unawaited(ref.read(proxyRepositoryProvider).urlTest(g.tag).run());
    }
    if (currentOk && !force && !upgrade) {
      _appliedFor = g.tag;
      return;
    }
    // не дёргать переключение чаще раза в 3 секунды (ядро шлёт обновления пачками)
    if (!force && DateTime.now().difference(_lastSwitch) < const Duration(seconds: 3)) return;
    if (best.isSelected) return;
    if (current == null || upgrade || isDelayTimeout(current.delay) && bestAlive || force) {
      _lastSwitch = DateTime.now();
      _appliedFor = g.tag;
      Logger.bootstrap.info("okno country: ${pref.isEmpty ? "авто" : pref} → ${best.tag} (was ${g.selected}${viaAuto ? "/${auto.groupSelectedTag}" : ""})");
      await ref.read(proxyRepositoryProvider).selectProxy(g.tag, best.tag).run();
      if (!isDelayKnown(best.delay)) {
        // пинг ещё не мерили — запустим, чтобы при таймауте сторож переехал на живой узел
        unawaited(ref.read(proxyRepositoryProvider).urlTest(g.tag).run());
      }
    }
  }
}

final oknoCountryGuardProvider = Provider<OknoCountryGuard>((ref) => OknoCountryGuard(ref));
