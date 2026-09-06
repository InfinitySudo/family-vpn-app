import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:path_provider/path_provider.dart';

/// Имя зашитого семейного профиля.
const String familyProfileName = "Окно";

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
      for (final u in Environment.subscriptionFallbacks.split(","))
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

/// Все кандидаты в порядке приоритета: сохранённые зеркала, зашитый адрес, зашитые запасные, GitHub.
Future<List<String>> familySubscriptionCandidates() async {
  final out = <String>[];
  for (final u in [...await storedMirrors(), Environment.subscriptionUrl, ...familySubscriptionFallbacks()]) {
    if (u.isNotEmpty && !out.contains(u)) out.add(u);
  }
  return out;
}

/// Быстрая проверка адреса: отвечает ли 200 и не пустым телом за [timeout].
/// Заблокированный IP в РФ висит на SYN — ждать 30+ секунд на каждом нельзя.
Future<bool> _reachable(String url, {Duration timeout = const Duration(seconds: 5)}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader, "Okno");
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != 200) return false;
    final body = await resp.transform(utf8.decoder).join().timeout(timeout);
    return body.trim().isNotEmpty;
  } catch (e) {
    Logger.bootstrap.debug("family profile: $url unreachable: $e");
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Первый доступный адрес подписки из [familySubscriptionCandidates] (null — ни один).
Future<String?> pickFamilySubscriptionUrl() async {
  for (final url in await familySubscriptionCandidates()) {
    if (await _reachable(url)) {
      Logger.bootstrap.info("family profile: using $url");
      unawaited(refreshMirrors(url)); // обновить список адресов на устройстве, не задерживая запуск
      return url;
    }
  }
  return null;
}

/// Подтягивает зашитую подписку с первого доступного адреса и делает её
/// активной. Старые семейные профили с другим адресом удаляются, чтобы не
/// плодить дубли при смене зеркала. Возвращает true, если профиль на месте.
Future<bool> ensureFamilyProfile(ProfileRepository repo) async {
  final candidates = await familySubscriptionCandidates();
  if (candidates.isEmpty) {
    Logger.bootstrap.warning("family profile: subscription_url is not set");
    return false;
  }
  final url = await pickFamilySubscriptionUrl();
  if (url == null) {
    Logger.bootstrap.warning("family profile: no subscription address reachable (${candidates.length} tried)");
    return false;
  }
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
