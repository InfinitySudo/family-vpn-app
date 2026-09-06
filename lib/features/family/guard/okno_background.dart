import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/features/settings/notifier/battery_optimization/battery_optimizations_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Окно: «чтобы не выключалось само» (Android).
///
/// Xiaomi/Redmi/POCO (MIUI), Samsung, Huawei, OPPO, vivo убивают VPN-службу в фоне,
/// если приложению не разрешена работа без ограничений — снаружи это «выкинуло»
/// через несколько секунд после подключения (06.09: Артём на Xiaomi, москвич на
/// Samsung; после «Нет ограничений» вылеты прекратились). Плашка на главном:
/// «Разрешить» → системный диалог «не оптимизировать батарею»; на MIUI ещё
/// «Автозапуск» → экран автозапуска. Скрывается, когда всё дано или пользователь
/// нажал «Готово» (метка в файле).
class OknoBackground {
  static const _ch = MethodChannel("com.hiddify.app/okno");

  static Future<Map<dynamic, dynamic>> deviceInfo() async {
    if (!Platform.isAndroid) return const {};
    try {
      final r = await _ch.invokeMethod<dynamic>("device_info");
      return r is Map ? r : const {};
    } catch (_) {
      return const {};
    }
  }

  static Future<bool> openAutostart() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>("open_autostart") ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<File> _doneFile() async => File("${(await getApplicationSupportDirectory()).path}/okno_background_done");
  static Future<bool> isDone() async => (await _doneFile()).existsSync();
  static Future<void> markDone() async {
    try { (await _doneFile()).writeAsStringSync(DateTime.now().toIso8601String()); } catch (_) {}
  }
}

final oknoDeviceInfoProvider = FutureProvider<Map<dynamic, dynamic>>((ref) => OknoBackground.deviceInfo());
final oknoBackgroundDoneProvider = FutureProvider<bool>((ref) => OknoBackground.isDone());

class BackgroundPermissionBanner extends ConsumerWidget {
  const BackgroundPermissionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final done = ref.watch(oknoBackgroundDoneProvider).valueOrNull ?? true;
    if (done) return const SizedBox.shrink();
    final ignoring = ref.watch(batteryOptimizationNotifierProvider).valueOrNull ?? true;
    final info = ref.watch(oknoDeviceInfoProvider).valueOrNull ?? const {};
    final miui = info["miui"] == true;
    final brand = "${info["manufacturer"] ?? ""}".trim();
    final needsAutostart = miui; // у остальных вендоров экрана автозапуска как правило нет / не нужен
    if (ignoring && !needsAutostart) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.battery_saver_rounded, color: cs.onSecondaryContainer),
                  const Gap(10),
                  Expanded(
                    child: Text(
                      "Чтобы Окно не выключалось само",
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: cs.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
              const Gap(6),
              Text(
                (brand.isEmpty ? "Телефон" : brand) +
                    " может закрывать VPN в фоне — тогда Окно «выкидывает» через несколько секунд. "
                    "Разрешите работу без ограничений" +
                    (needsAutostart ? " и включите автозапуск." : "."),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSecondaryContainer),
              ),
              const Gap(8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (!ignoring)
                    FilledButton.tonal(
                      onPressed: () => ref.read(batteryOptimizationNotifierProvider.notifier).requestToIgnore(),
                      child: const Text("Разрешить работу в фоне"),
                    ),
                  if (needsAutostart)
                    FilledButton.tonal(
                      onPressed: OknoBackground.openAutostart,
                      child: const Text("Автозапуск"),
                    ),
                  TextButton(
                    onPressed: () async {
                      await OknoBackground.markDone();
                      ref.invalidate(oknoBackgroundDoneProvider);
                    },
                    child: const Text("Готово"),
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
