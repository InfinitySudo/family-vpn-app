import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

/// Имя зашитого семейного профиля.
const String familyProfileName = "Окно";

/// Запасные адреса той же семейной подписки. 04.09 IP Риги (217.60.2.82) точечно
/// заблокировали в РФ по TCP: ping шёл, соседние IP были доступны, а наш — нет.
/// Приложение знало один адрес → «не удалось получить настройки». Теперь адреса
/// перебираются по порядку: зеркала на узлах флота (сквозной кэш агрегатора Риги),
/// стабильный адрес на GitHub (не зависит от IP серверов), и сама Рига последней.
const List<String> familySubscriptionFallbacks = [
  "http://46.8.238.102:2097/okno/38fa3eb3adb9258d",
  "http://151.242.69.245:2097/okno/38fa3eb3adb9258d", // Амстердам (NL), 05.09; узел .158 выведен
  "https://raw.githubusercontent.com/InfinitySudo/family-vpn-app/sub/sub.txt",
  "http://95.182.90.237:2097/okno/38fa3eb3adb9258d", // второй IP Риги (05.09), из РФ открывается
  "http://217.60.2.82:2097/okno/38fa3eb3adb9258d",
];

/// Все кандидаты в порядке приоритета: зашитый в сборку адрес, затем запасные.
List<String> familySubscriptionCandidates() {
  final out = <String>[];
  for (final u in [Environment.subscriptionUrl, ...familySubscriptionFallbacks]) {
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
  for (final url in familySubscriptionCandidates()) {
    if (await _reachable(url)) {
      Logger.bootstrap.info("family profile: using $url");
      return url;
    }
  }
  return null;
}

/// Подтягивает зашитую подписку с первого доступного адреса и делает её
/// активной. Старые семейные профили с другим адресом удаляются, чтобы не
/// плодить дубли при смене зеркала. Возвращает true, если профиль на месте.
Future<bool> ensureFamilyProfile(ProfileRepository repo) async {
  final candidates = familySubscriptionCandidates();
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
