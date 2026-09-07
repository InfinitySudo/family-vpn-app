import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:path_provider/path_provider.dart';

/// Имя зашитого семейного профиля.
const String familyProfileName = "Окно";

/// Состояние доступа — показывает главный экран: нужен ключ / срок вышел / нет сервера.
enum OknoAccess { unknown, ok, needKey, expired, noServer }

final ValueNotifier<OknoAccess> oknoAccess = ValueNotifier(OknoAccess.unknown);

/// Семейная сборка: ключ зашит в `subscription_url` (…/okno/<id>). Публичная сборка получает
/// в `subscription_url` только адрес агрегатора (http://ip:2097) и берёт ключ через бота.
bool get familyBuild => Environment.subscriptionUrl.contains("/okno/");

File? _keyFile;
Future<File?> _keyStore() async {
  if (_keyFile != null) return _keyFile;
  try {
    _keyFile = File("${(await getApplicationSupportDirectory()).path}/okno_key.json");
  } catch (_) {}
  return _keyFile;
}

/// Личный ключ, полученный через бота: {"sub": url, "mirrors": [...]}.
Future<Map<String, dynamic>?> storedKey() async {
  try {
    final f = await _keyStore();
    if (f == null || !f.existsSync()) return null;
    final j = jsonDecode(f.readAsStringSync());
    if (j is Map && "${j["sub"]}".startsWith("http")) return Map<String, dynamic>.from(j);
  } catch (e) {
    Logger.bootstrap.debug("family profile: stored key unreadable: $e");
  }
  return null;
}

Future<void> saveKey(String sub, List<String> mirrors) async {
  final f = await _keyStore();
  if (f == null) return;
  f.writeAsStringSync(jsonEncode({"sub": sub, "mirrors": mirrors, "saved": DateTime.now().toIso8601String()}), flush: true);
}

/// Адреса агрегатора (только origin) для привязки ключа: сохранённые зеркала, зашитые адреса.
Future<List<String>> pairingBases() async {
  final out = <String>[];
  for (final u in [...await storedMirrors(), Environment.subscriptionUrl, ...familySubscriptionFallbacks()]) {
    if (!u.startsWith("http") || u.contains("githubusercontent")) continue;
    try {
      final o = Uri.parse(u).origin;
      if (!out.contains(o)) out.add(o);
    } catch (_) {}
  }
  return out;
}

/// Адреса семейной подписки — три слоя:
///  1. сохранённый на устройстве список зеркал (`okno_mirrors.json`): после каждого
///     удачного обращения приложение забирает у агрегатора `<url>/mirrors` и хранит его.
///     Флот может ротироваться (сторож заменяет узлы, попавшие под блокировку) —
///     старые сборки продолжают находить подписку без переустановки;
///  2. зашитые в сборку адреса: `subscription_url` + `subscription_fallbacks`
///     (секреты сборки, в репозитории их нет) — только для первого запуска;
///  3. стабильный публичный адрес на GitHub (не зависит от IP серверов).
const String familyGithubFallback = "https://raw.githubusercontent.com/InfinitySudo/family-vpn-app/sub/sub.txt";

List<String> familySubscriptionFallbacks() => [
      // разделитель «;» (flutter_distributor режет --build-dart-define по запятым), запятую тоже принимаем
      for (final u in Environment.subscriptionFallbacks.split(RegExp(r"[;,]")))
        if (u.trim().isNotEmpty) u.trim(),
      familyGithubFallback,
    ];

File? _mirrorsFile;
Future<File?> _mirrorsStore() async {
  if (_mirrorsFile != null) return _mirrorsFile;
  try {
    _mirrorsFile = File("${(await getApplicationSupportDirectory()).path}/okno_mirrors.json");
  } catch (_) {}
  return _mirrorsFile;
}

Future<List<String>> storedMirrors() async {
  try {
    final f = await _mirrorsStore();
    if (f == null || !f.existsSync()) return const [];
    final j = jsonDecode(f.readAsStringSync());
    final list = (j is Map ? j["mirrors"] : j) as List?;
    return [for (final e in list ?? const []) if ("$e".startsWith("http")) "$e"];
  } catch (e) {
    Logger.bootstrap.debug("family profile: stored mirrors unreadable: $e");
    return const [];
  }
}

/// Забирает свежий список зеркал у агрегатора и сохраняет. Тихо: любая ошибка — просто без обновления.
Future<void> refreshMirrors(String subscriptionUrl) async {
  if (!subscriptionUrl.contains("/okno/")) return; // GitHub raw и прочее — списка не отдают
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.getUrl(Uri.parse("$subscriptionUrl/mirrors")).timeout(const Duration(seconds: 5));
    req.headers.set(HttpHeaders.userAgentHeader, "Okno");
    final resp = await req.close().timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return;
    final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
    final j = jsonDecode(body);
    final list = [for (final e in ((j is Map ? j["mirrors"] : null) as List? ?? const [])) if ("$e".startsWith("http")) "$e"];
    if (list.isEmpty) return;
    final f = await _mirrorsStore();
    if (f == null) return;
    f.writeAsStringSync(jsonEncode({"mirrors": list, "saved": DateTime.now().toIso8601String()}), flush: true);
    Logger.bootstrap.info("family profile: mirrors saved (${list.length})");
  } catch (e) {
    Logger.bootstrap.debug("family profile: mirrors refresh failed: $e");
  } finally {
    client.close(force: true);
  }
}

/// Все кандидаты в порядке приоритета. Личный ключ: его зеркала (сохранённые и из ответа бота) + адрес.
/// Семейная сборка: сохранённые зеркала, зашитый адрес, зашитые запасные, GitHub.
Future<List<String>> familySubscriptionCandidates() async {
  final out = <String>[];
  final key = await storedKey();
  if (key != null) {
    final sub = "${key["sub"]}";
    final subid = sub.split("/okno/").last.split("/").first;
    for (final u in [
      for (final m in await storedMirrors()) if (m.contains(subid)) m,
      for (final m in (key["mirrors"] as List? ?? const [])) "$m",
      sub,
    ]) {
      if (u.startsWith("http") && !out.contains(u)) out.add(u);
    }
    return out;
  }
  if (!familyBuild) return out; // публичная сборка без ключа — нужна привязка через бота
  for (final u in [...await storedMirrors(), Environment.subscriptionUrl, ...familySubscriptionFallbacks()]) {
    if (u.isNotEmpty && !out.contains(u)) out.add(u);
  }
  return out;
}

/// Быстрая проверка адреса: отвечает ли 200 и не пустым телом за [timeout].
/// Заблокированный IP в РФ висит на SYN — ждать 30+ секунд на каждом нельзя.
/// Возвращает HTTP-статус (200 — годится, 402 — ключ истёк/выключен), 0 — не ответил.
Future<int> _probe(String url, {Duration timeout = const Duration(seconds: 5)}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader, "Okno");
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != 200) return resp.statusCode;
    final body = await resp.transform(utf8.decoder).join().timeout(timeout);
    return body.trim().isNotEmpty ? 200 : 0;
  } catch (e) {
    Logger.bootstrap.debug("family profile: $url unreachable: $e");
    return 0;
  } finally {
    client.close(force: true);
  }
}


/// Первый доступный адрес подписки из [familySubscriptionCandidates] (null — ни один).
Future<String?> pickFamilySubscriptionUrl() async {
  var expired = false;
  for (final url in await familySubscriptionCandidates()) {
    final st = await _probe(url);
    if (st == 200) {
      Logger.bootstrap.info("family profile: using $url");
      unawaited(refreshMirrors(url)); // обновить список адресов на устройстве, не задерживая запуск
      return url;
    }
    if (st == 402) expired = true; // сервер ответил: срок вышел — дальше перебирать бессмысленно
  }
  if (expired) {
    Logger.bootstrap.warning("family profile: key expired (402)");
    oknoAccess.value = OknoAccess.expired;
  }
  return null;
}

/// Подтягивает зашитую подписку с первого доступного адреса и делает её
/// активной. Старые семейные профили с другим адресом удаляются, чтобы не
/// плодить дубли при смене зеркала. Возвращает true, если профиль на месте.
Future<bool> ensureFamilyProfile(ProfileRepository repo) async {
  final candidates = await familySubscriptionCandidates();
  if (candidates.isEmpty) {
    Logger.bootstrap.warning("family profile: no key yet (public build) — pairing via bot");
    oknoAccess.value = OknoAccess.needKey;
    return false;
  }
  oknoAccess.value = OknoAccess.unknown;
  final url = await pickFamilySubscriptionUrl();
  if (url == null) {
    Logger.bootstrap.warning("family profile: no subscription address reachable (${candidates.length} tried)");
    if (oknoAccess.value != OknoAccess.expired) oknoAccess.value = OknoAccess.noServer;
    return false;
  }
  oknoAccess.value = OknoAccess.ok;
  final result = await repo
      .upsertRemote(url, userOverride: const UserOverride(name: familyProfileName, updateInterval: 6))
      .run();
  final ok = result.match((failure) {
    Logger.bootstrap.warning("family profile: fetch failed: $failure");
    return false;
  }, (_) => true);

  try {
    final all = (await repo.watchAll().first).getOrElse((_) => <ProfileEntity>[]);
    final family = all.where((p) => p is RemoteProfileEntity && p.url == url).toList();
    final active = (await repo.watchActiveProfile().first).getOrElse((_) => null);
    if (ok && family.isNotEmpty) {
      // семейный профиль с рабочего адреса — активен; дубли с других адресов долой
      if (active == null || active.id != family.first.id) {
        await repo.setAsActive(family.first.id).run();
      }
      for (final p in all) {
        if (p is RemoteProfileEntity && p.name == familyProfileName && p.url != url) {
          await repo.deleteById(p.id, active?.id == p.id).run();
        }
      }
    } else if (active == null && all.isNotEmpty) {
      await repo.setAsActive(all.first.id).run();
    }
  } catch (e) {
    Logger.bootstrap.warning("family profile: could not activate: $e");
  }
  return ok;
}
