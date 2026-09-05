import 'dart:async';

import 'package:circle_flags/circle_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/features/family/country/okno_country.dart';
import 'package:hiddify/features/family/country/okno_country_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// ─────────────────────────── цвета/форматирование пинга ───────────────────────────

Color pingColor(BuildContext context, int delay) {
  if (!isDelayKnown(delay)) return Theme.of(context).colorScheme.onSurfaceVariant;
  if (isDelayTimeout(delay)) return Theme.of(context).colorScheme.error;
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (delay < 150) return dark ? Colors.lightGreenAccent.shade400 : Colors.green.shade700;
  if (delay < 400) return Colors.orange.shade700;
  return Theme.of(context).colorScheme.error;
}

String pingText(int delay) {
  if (!isDelayKnown(delay)) return "…";
  if (isDelayTimeout(delay)) return "нет ответа";
  return "$delay мс";
}

/// Бейдж «▮▮▮ 85 мс» с полосками уровня сигнала.
class PingBadge extends StatelessWidget {
  const PingBadge({super.key, required this.delay, this.compact = false});
  final int delay;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = pingColor(context, delay);
    final bars = !isDelayKnown(delay) ? 0 : isDelayTimeout(delay) ? 0 : delay < 150 ? 3 : delay < 400 ? 2 : 1;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SignalBars(level: bars, color: color),
          const Gap(6),
          Text(
            pingText(delay),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.level, required this.color});
  final int level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 3; i++) ...[
          Container(
            width: 3,
            height: 4.0 + i * 3,
            decoration: BoxDecoration(
              color: i <= level ? color : color.withValues(alpha: .25),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          if (i < 3) const Gap(1.5),
        ],
      ],
    );
  }
}

/// Чип «AI ✓» — из этой страны работают ChatGPT и другие AI-сервисы.
class AiChip extends StatelessWidget {
  const AiChip({super.key, required this.ok});
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ok ? scheme.primary : scheme.error;
    return Tooltip(
      message: ok ? "ChatGPT и другие AI-сервисы доступны" : "AI-сервисы из этой страны не работают",
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: .6)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ok ? Icons.auto_awesome_rounded : Icons.block_rounded, size: 12, color: color),
            const Gap(3),
            Text("AI", style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────── флаг с достопримечательностью ───────────────────────────

/// Круглый флаг. Наведение мышью (ПК) или долгое нажатие (телефон) показывает
/// карточку с фотографией достопримечательности страны.
class LandmarkFlag extends StatefulWidget {
  const LandmarkFlag({super.key, required this.country, this.size = 44});
  final OknoCountry country;
  final double size;

  @override
  State<LandmarkFlag> createState() => _LandmarkFlagState();
}

class _LandmarkFlagState extends State<LandmarkFlag> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  Timer? _autoHide;

  void _show({Duration? autoHide}) {
    if (!widget.country.hasLandmark) return;
    _autoHide?.cancel();
    if (!_portal.isShowing) _portal.show();
    if (autoHide != null) _autoHide = Timer(autoHide, _hide);
  }

  void _hide() {
    _autoHide?.cancel();
    if (_portal.isShowing) _portal.hide();
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flag = ClipOval(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: widget.country.code.length == 2
            ? CircleFlag(widget.country.code.toLowerCase(), size: widget.size)
            : Icon(Icons.public_rounded, size: widget.size * .7),
      ),
    );
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => Stack(
        children: [
          // тап мимо — закрыть (для телефона)
          Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _hide)),
          CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            offset: const Offset(0, -8),
            showWhenUnlinked: false,
            child: _LandmarkCard(country: widget.country),
          ),
        ],
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) => _show(),
          onExit: (_) => _hide(),
          child: GestureDetector(
            onLongPress: () => _show(autoHide: const Duration(seconds: 5)),
            child: Semantics(label: widget.country.name, child: flag),
          ),
        ),
      ),
    );
  }
}

class _LandmarkCard extends StatelessWidget {
  const _LandmarkCard({required this.country});
  final OknoCountry country;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surface,
      child: SizedBox(
        width: 240,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.asset(
                country.assetPath,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Text(country.flagEmoji, style: const TextStyle(fontSize: 48)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(country.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text(country.landmark, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    )._fadeIn();
  }
}

extension on Widget {
  Widget _fadeIn() => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (_, v, child) => Opacity(opacity: v, child: Transform.scale(scale: .96 + .04 * v, child: child)),
        child: this,
      );
}

// ─────────────────────────── карточка на главном экране ───────────────────────────

/// Карточка «Страна» под заголовком главного экрана: флаг, страна, пинг, чип AI.
/// Нажатие открывает список стран.
class CountryCard extends HookConsumerWidget {
  const CountryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(oknoCountryGuardProvider); // держим сторожа живым, пока виден главный экран
    final theme = Theme.of(context);
    final pref = ref.watch(oknoCountryPref);
    final state = ref.watch(oknoCountriesProvider).valueOrNull;

    final effectiveCode = pref.isNotEmpty ? pref : (state?.selectedCountry ?? "");
    final country = effectiveCode.isEmpty ? null : OknoCountry.byCode(effectiveCode);
    final stat = country == null ? null : state?.byCode(country.code);
    final delay = stat?.bestDelay ?? 0;

    final title = country == null ? "Страна: авто" : country.name;
    final String subtitle;
    if (state == null || state.countries.isEmpty) {
      subtitle = "список серверов появится после загрузки настроек";
    } else if (country == null) {
      subtitle = "самый быстрый сервер · нажмите, чтобы выбрать страну";
    } else if (stat == null) {
      subtitle = "серверов этой страны сейчас нет — выберите другую";
    } else {
      final n = stat.servers.length;
      final srv = n == 1 ? "1 сервер" : (n < 5 ? "$n сервера" : "$n серверов");
      subtitle = "${country.city.isNotEmpty ? "${country.city} · " : ""}$srv · ${state.live ? "пинг через VPN" : "отклик сервера"}";
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showCountryPicker(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                if (country != null)
                  LandmarkFlag(country: country, size: 44)
                else
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.primaryContainer),
                    child: Icon(Icons.bolt_rounded, color: theme.colorScheme.onPrimaryContainer),
                  ),
                const Gap(12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (country != null) ...[const Gap(8), AiChip(ok: country.aiFriendly)],
                        ],
                      ),
                      const Gap(2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Gap(8),
                if (stat != null) PingBadge(delay: delay, compact: true),
                Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── список стран (нижний лист) ───────────────────────────

Future<void> showCountryPicker(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (_) => const CountryPickerSheet(),
  );
}

class CountryPickerSheet extends HookConsumerWidget {
  const CountryPickerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pref = ref.watch(oknoCountryPref);
    final async = ref.watch(oknoCountriesProvider);
    final actions = ref.read(oknoCountryActionsProvider);
    final refreshing = useState(false);

    // при открытии — сразу перемерить пинг
    useEffect(() {
      unawaited(actions.refreshPing());
      return null;
    }, const []);

    Future<void> refresh() async {
      refreshing.value = true;
      try {
        await actions.refreshPing();
        await Future<void>.delayed(const Duration(milliseconds: 600));
      } finally {
        if (context.mounted) refreshing.value = false;
      }
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .7,
      minChildSize: .4,
      maxChildSize: .95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text("Страна подключения", style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ),
              IconButton.filledTonal(
                tooltip: "Проверить пинг",
                onPressed: refreshing.value ? null : refresh,
                icon: refreshing.value
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check_rounded),
              ),
            ],
          ),
          const Gap(6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome_rounded, size: 20, color: theme.colorScheme.onPrimaryContainer),
                const Gap(10),
                Expanded(
                  child: Text(
                    "ChatGPT и другие AI-сервисы смотрят на страну вашего адреса. "
                    "Выберите одну страну — она сохранится и будет включаться при каждом подключении, "
                    "адрес не будет «прыгать».",
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                  ),
                ),
              ],
            ),
          ),
          const Gap(12),
          ...async.when(
            loading: () => [const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [Padding(padding: const EdgeInsets.all(16), child: Text("Не удалось получить список: $e"))],
            data: (state) => [
              _AutoTile(
                selected: pref.isEmpty,
                current: state.selectedCountry.isEmpty ? null : OknoCountry.byCode(state.selectedCountry),
                delay: state.auto?.delay ?? 0,
                onTap: () => actions.choose(""),
              ),
              const Gap(4),
              if (state.countries.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    "Серверов пока нет — настройки ещё не загрузились. Проверьте интернет и попробуйте позже.",
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final stat in state.countries) ...[
                _CountryTile(
                  stat: stat,
                  selected: pref == stat.country.code,
                  live: state.live,
                  onTap: () => actions.choose(stat.country.code),
                ),
                const Gap(4),
              ],
              const Gap(8),
              Text(
                state.live
                    ? "Пинг измерен через VPN — так его видят сайты. Подсказка: подержите палец на флаге (или наведите мышь) — покажем, что там красивого."
                    : "Пока не подключены, показываем отклик сервера напрямую. «Нет ответа» — адрес заблокирован у вашего провайдера, приложение при подключении обойдёт его. Подержите палец на флаге — покажем достопримечательность.",
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AutoTile extends StatelessWidget {
  const _AutoTile({required this.selected, required this.current, required this.delay, required this.onTap});
  final bool selected;
  final OknoCountry? current;
  final int delay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _PickTile(
      selected: selected,
      onTap: onTap,
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.primaryContainer),
        child: Icon(Icons.bolt_rounded, color: theme.colorScheme.onPrimaryContainer, size: 28),
      ),
      title: "Авто",
      subtitle: current == null
          ? "самый быстрый сервер, страна может меняться"
          : "самый быстрый сервер · сейчас ${current!.flagEmoji} ${current!.name}",
      trailing: isDelayKnown(delay) ? PingBadge(delay: delay) : null,
    );
  }
}

class _CountryTile extends StatelessWidget {
  const _CountryTile({required this.stat, required this.selected, required this.live, required this.onTap});
  final OknoCountryStat stat;
  final bool selected;
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = stat.country;
    final n = stat.servers.length;
    final alive = stat.servers.where((s) => isDelayKnown(s.delay) && !isDelayTimeout(s.delay)).length;
    final tested = stat.servers.where((s) => isDelayKnown(s.delay)).length;
    final srv = n == 1 ? "1 сервер" : (n < 5 ? "$n сервера" : "$n серверов");
    final health = tested == 0 ? "" : " · отвечают $alive из $n";
    return _PickTile(
      selected: selected,
      onTap: onTap,
      leading: LandmarkFlag(country: c, size: 48),
      title: c.name,
      titleExtra: AiChip(ok: c.aiFriendly),
      subtitle: "${c.city.isNotEmpty ? "${c.city} · " : ""}$srv$health",
      trailing: PingBadge(delay: stat.bestDelay),
    );
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.titleExtra,
    this.trailing,
  });
  final bool selected;
  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final Widget? titleExtra;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              leading,
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (titleExtra != null) ...[const Gap(8), titleExtra!],
                      ],
                    ),
                    const Gap(2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Gap(8),
              if (trailing != null) trailing!,
              const Gap(8),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
