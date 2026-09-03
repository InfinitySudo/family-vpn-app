import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

/// Имя зашитого семейного профиля.
const String familyProfileName = "Окно";

/// Подтягивает зашитую подписку ([Environment.subscriptionUrl]) и делает её
/// активной, если активного профиля ещё нет. Возвращает true, если профиль на месте.
Future<bool> ensureFamilyProfile(ProfileRepository repo) async {
  final url = Environment.subscriptionUrl;
  if (url.isEmpty) {
    Logger.bootstrap.warning("family profile: subscription_url is not set");
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
    final active = (await repo.watchActiveProfile().first).getOrElse((_) => null);
    if (active == null) {
      final all = (await repo.watchAll().first).getOrElse((_) => <ProfileEntity>[]);
      if (all.isNotEmpty) {
        final family = all.firstWhere(
          (p) => p is RemoteProfileEntity && p.url == url,
          orElse: () => all.first,
        );
        await repo.setAsActive(family.id).run();
      }
    }
  } catch (e) {
    Logger.bootstrap.warning("family profile: could not activate: $e");
  }
  return ok;
}
