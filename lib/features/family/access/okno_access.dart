import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/features/family/family_no_server_notice.dart';
import 'package:hiddify/features/family/family_profile.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Доступ через Telegram-бота без ручного ввода ключа.
/// Приложение придумывает код + секрет, открывает бота `/start p_<код>_<секрет>`, бот выдаёт ключ
/// и кладёт привязку на агрегатор; приложение опрашивает `/okno/pair/<код>?t=<секрет>` и
/// само подхватывает подписку. Работает на всех платформах: на компьютере — ещё и QR для телефона.
const String oknoBot = "OKHO_VPN_BOT";

String _rand(int n) {
  const a = "abcdefghijkmnpqrstuvwxyz23456789";
  final r = Random.secure();
  return List.generate(n, (_) => a[r.nextInt(a.length)]).join();
}

Future<({String code, String token})> _pairIds() async {
  File? f;
  try {
    f = File("${(await getApplicationSupportDirectory()).path}/okno_pair.json");
    if (f.existsSync()) {
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map && "${j["code"]}".length >= 6) return (code: "${j["code"]}", token: "${j["token"]}");
    }
  } catch (_) {}
  final ids = (code: _rand(10), token: _rand(16));
  try {
    f?.writeAsStringSync(jsonEncode({"code": ids.code, "token": ids.token}), flush: true);
  } catch (_) {}
  return ids;
}

/// Один опрос всех адресов агрегатора. true — ключ получен и сохранён.
Future<bool> pollPairing(String code, String token) async {
  for (final base in await pairingBases()) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(Uri.parse("$base/okno/pair/$code?t=$token")).timeout(const Duration(seconds: 4));
      req.headers.set(HttpHeaders.userAgentHeader, "Okno");
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final j = jsonDecode(await resp.transform(utf8.decoder).join());
        final sub = "${j["sub"]}";
        if (!sub.startsWith("http")) continue;
        await saveKey(sub, [for (final m in (j["mirrors"] as List? ?? const [])) "$m"]);
        Logger.bootstrap.info("pairing: key received via $base");
        return true;
      }
      if (resp.statusCode == 404 || resp.statusCode == 403) return false; // агрегатор ответил — ждём бота
    } catch (e) {
      Logger.bootstrap.debug("pairing: $base failed: $e");
    } finally {
      client.close(force: true);
    }
  }
  return false;
}

/// Вместо профиля, когда его нет: нужен ключ / срок вышел / нет сервера.
class OknoAccessNotice extends HookConsumerWidget {
  const OknoAccessNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = useValueListenable(oknoAccess);
    return switch (access) {
      OknoAccess.needKey => const _PairCard(),
      OknoAccess.expired => const _ExpiredCard(),
      _ => const FamilyNoServerNotice(),
    };
  }
}

/// Под карточкой профиля: «срок вышел» даже когда профиль ещё на месте.
class OknoAccessBanner extends HookConsumerWidget {
  const OknoAccessBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = useValueListenable(oknoAccess);
    if (access != OknoAccess.expired) return const SizedBox.shrink();
    return const _ExpiredCard();
  }
}

class _PairCard extends HookConsumerWidget {
  const _PairCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ids = useFuture(useMemoized(_pairIds));
    final waiting = useState(false);
    final done = useState(false);
    final code = ids.data?.code;
    final token = ids.data?.token;
    final link = code == null ? null : "https://t.me/$oknoBot?start=p_${code}_$token";
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    useEffect(() {
      if (code == null || token == null) return null;
      final timer = Timer.periodic(const Duration(seconds: 3), (t) async {
        if (done.value) return;
        if (await pollPairing(code, token)) {
          done.value = true;
          t.cancel();
          try {
            final repo = ref.read(profileRepositoryProvider).requireValue;
            await ensureFamilyProfile(repo);
          } catch (e) {
            Logger.bootstrap.warning("pairing: profile failed: $e");
          }
        }
      });
      return timer.cancel;
    }, [code, token]);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        children: [
          Icon(Icons.vpn_key_rounded, size: 44, color: theme.colorScheme.primary),
          const Gap(12),
          Text(
            done.value
                ? "Ключ получен — подключаем…"
                : "Чтобы включить «Окно», нужен ключ.\nНажми кнопку — откроется Telegram, там нажми «Start».\nВернись сюда: доступ подключится сам за пару секунд.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          const Gap(16),
          FilledButton.icon(
            onPressed: link == null || done.value
                ? null
                : () async {
                    waiting.value = true;
                    await UriUtils.tryLaunch(Uri.parse(link));
                  },
            icon: const Icon(Icons.telegram),
            label: const Text("Получить доступ в Telegram"),
          ),
          if (waiting.value && !done.value) ...[
            const Gap(12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const Gap(8),
                Text("Ждём подтверждения из Telegram…", style: theme.textTheme.bodyMedium),
              ],
            ),
          ],
          if (desktop && link != null) ...[
            const Gap(16),
            Text("Или отсканируй телефоном:", style: theme.textTheme.bodyMedium),
            const Gap(8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
              child: QrImageView(data: link, size: 150),
            ),
          ],
          const Gap(8),
          Text("Первые 3 дня бесплатно.", style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ExpiredCard extends HookConsumerWidget {
  const _ExpiredCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final busy = useState(false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(Icons.timer_off_rounded, size: 36, color: theme.colorScheme.onErrorContainer),
              const Gap(8),
              Text(
                "Срок доступа закончился.\nОплати в Telegram — и нажми «Проверить».",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
              const Gap(12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => UriUtils.tryLaunch(Uri.parse("https://t.me/$oknoBot?start=pay")),
                    icon: const Icon(Icons.payment_rounded),
                    label: const Text("Оплатить"),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy.value
                        ? null
                        : () async {
                            busy.value = true;
                            try {
                              final repo = ref.read(profileRepositoryProvider).requireValue;
                              await ensureFamilyProfile(repo);
                            } finally {
                              busy.value = false;
                            }
                          },
                    icon: busy.value
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh_rounded),
                    label: const Text("Проверить"),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
