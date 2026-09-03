import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/features/family/family_profile.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Показывается, когда зашитая подписка ещё не загрузилась (нет интернета при
/// первом запуске). Одна кнопка «Повторить».
class FamilyNoServerNotice extends HookConsumerWidget {
  const FamilyNoServerNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
      child: Column(
        children: [
          Icon(Icons.wifi_off_rounded, size: 48, color: theme.colorScheme.error),
          const Gap(12),
          Text(
            "Не удалось получить настройки с сервера.\nПроверьте, что есть интернет, и нажмите «Повторить».",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          const Gap(16),
          FilledButton.icon(
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
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
            label: const Text("Повторить"),
          ),
        ],
      ),
    );
  }
}
